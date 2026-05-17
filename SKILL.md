---
name: anki-toeic-add
description: 透過 AnkiConnect API（localhost:8765）新增英文單字卡到使用者的 Anki TOEIC 牌組（note type：英文單字，8 個欄位）。**也是 `/toeic` 斜線指令的完整實作**（`/toeic <英文單字>` 會走這個 skill）。Trigger 詞包括："加單字到 Anki"、"幫我加 X 到 TOEIC"、"建單字卡 X"、"新增 Anki 卡片"、"TOEIC 加卡 X"、"幫我把這幾個單字做成 anki"、"add X to my Anki"、"make a flashcard for X"、"create Anki card for word"。使用者可能只丟單字列表、句子裡的生字、或一段英文文章請你挑生字。Skill 會自動產生中文翻譯、KK 音標、詞性、字根字首拆解、例句，並用 edge-tts 的 AvaNeural 聲音產生英文發音 mp3 嵌入卡片（不靠 Anki 內建 TTS，跨裝置都聽得到 Ava 級的聲音），最後呼叫 AnkiConnect 推入 TOEIC 牌組。預設不重複加同字、不問確認、不要 dry-run。
---

## 解析使用者輸入

不論觸發來源是 `/toeic <args>`、自然語言（"幫我加 X 到 TOEIC"），或從文章中挑字，輸入處理一致：

- 單字列表：`ubiquitous`、`ubiquitous, diligent, mitigate`、`ubiquitous diligent` 都接受
- 中文導引混雜英文：`加 mitigate, advocate` — 抽出 `mitigate`、`advocate`
- 一段英文文章（>30 詞）：改用「挑出 5-10 個 TOEIC 等級的關鍵生字」模式 — 先**列建議單字請使用者確認**，再批次加（這是少數需要確認的情境）
- 輸入為空：請使用者補單字

抽 token 規則：regex `[A-Za-z][A-Za-z\-]*`；過濾常見導引詞（toeic、anki、word、add、card、flashcard、make、create、TOEIC、Anki 等）。

# Anki TOEIC Add

新增英文單字卡到使用者的 Anki TOEIC 牌組。整個流程：產生 8 個欄位內容（含自動產 Ava 音檔）→ 呼叫 AnkiConnect → 報告結果。

## Setup state（已配置好）

- Anki desktop 已安裝；AnkiConnect 插件（2055492159）已裝、在 Anki 開啟時自動於 `http://127.0.0.1:8765` 服務 HTTP API
- 牌組：`TOEIC`
- Note type：`英文單字`（**8 欄位**，順序：中文 / English / KK音標 / 發音說明 / 詞性 / 解說 / 例句 / **Audio**）
- 2 張卡的模板（Card 1 中→英、Card 2 英→中）— **英文發音改用嵌入式 mp3**（`{{Audio}}`），不再用 `{{tts en_US:English}}`。原因：AnkiMobile (iOS) 的 TTS 預設聲音沙啞，預生成 mp3 跨裝置都好聽
- 中文那行還是 `{{tts zh_TW:中文}}`（中文不靠聽、留 TTS 省空間）
- `uv` / `uvx` 已裝在 `C:\Users\bacon\.local\bin\`，用來免安裝跑 edge-tts
- PowerShell 函式 `Add-AnkiCard`、`New-AnkiTtsAudio`、`Test-AnkiCardExists`、`Test-AnkiConnect` 在 `scripts/Add-AnkiCard.ps1`

## 觸發後的執行流程

1. **檢查 Anki 在跑**：呼叫 AnkiConnect `version`，若連不上請使用者開啟 Anki
2. **查重**：對每個要加的單字呼叫 `findNotes "deck:TOEIC English:<word>"`，已存在的略過並告知使用者
3. **產生內容**（每個新單字）：照下面的「欄位風格指南」生內容
4. **批次呼叫 `Add-AnkiCard`** 把每筆推進 Anki
5. **同步到 AnkiWeb**：批次完成後，若至少有一張卡成功新增，呼叫 AnkiConnect `sync` action 把本地 Anki 推到 AnkiWeb（使用者手機才會馬上收到新卡）。若 0 張成功（全跳過或全失敗），不必 sync。
6. **回報**：列出成功新增的 noteId + 單字，跳過的單字也要列，最後加一行 `☁️ 已同步到 AnkiWeb`（或 `⚠️ AnkiWeb 同步失敗：<原因>`）

### 同步的呼叫方式

```powershell
$r = Invoke-RestMethod -Uri http://127.0.0.1:8765 -Method Post -ContentType 'application/json' `
    -Body '{"action":"sync","version":6}'
if ($r.error) { "sync failed: $($r.error)" } else { "synced" }
```

`sync` 是非同步的（等於使用者按了同步按鈕），失敗常見原因：未登入 AnkiWeb、衝突需手動解決、網路斷線。失敗不要重試，告訴使用者去 Anki 桌面看狀態。

不要問「要加哪些？」「現在加嗎？」「先預覽嗎？」之類的確認題 — 使用者已經給單字了就直接做。失敗才停下來討論。

## 欄位風格指南

### 1. 中文（純文字，簡短）
- 主要 1-2 個意思，太多會塞爆 Card 1 正面
- 多個意思用 `&nbsp;&nbsp;` 隔（兩個空白比較好讀）或 `/`
- 範例：
  - `行人`
  - `跪著`
  - `自家車庫&nbsp;&nbsp;汽車修理廠`
  - `示意圖 / 圖解的`

### 2. English（單字本身）
- 預設小寫；專有名詞或慣用首字大寫的詞才大寫
- 一個 note 一個字（同字根的衍生詞另開 note）
- 不要包 `<b>` 或其他 HTML 標籤 — 模板已經處理樣式

### 3. KK音標（只有 IPA！）
- **只放純 `/IPA/`**，不要 `<a href="...">` 包裹、不要 `<h2>KK 音標</h2>` 標題、不要任何發音解釋
- 範例：`/pəˈdɛstrɪən/`、`/ˈnilɪŋ/`、`/skɪˈmætɪk/`
- 發音的提醒/重音說明放到下個欄位「發音說明」

### 4. 發音說明（可空，只在有 gotcha 時填）
- **大多數單字留空白**。只有以下情況才填：
  - 不發音字母（silent letter）：knife 的 K、psychology 的 P、wrist 的 W
  - 重音不直觀或容易念錯：'record (n.) vs re'cord (v.)
  - 母音怪異發音：cough/though/through/tough 那類
- 短 HTML，1-2 行，前面用 `<b>標籤：</b>` 突出主題
- 範例：
  - `<b>Silent K：</b>字首的 K 不發音（同 knife、know），中古英語演變遺留。`
  - `重音在第一音節 <code>/ˈspɛk/</code>；字尾 <code>-or</code> 發弱化捲舌音 <code>/ɚ/</code>。`

### 5. 詞性（簡短）
- 一行內描述，用括號 `(Noun)(Verb)` 或中文 `名詞、動詞`
- 多用法可以列各用法的中文意思
- 範例：
  - `(Noun)(Verb)`
  - `動名詞`
  - `作名詞：行人&nbsp;&nbsp;作形容詞：行人的 / 徒步的`

### 6. 解說（rich HTML，字根字首拆解）
這欄是學習主力 — **字源 / 字根字首拆解**。

結構建議（不必每段都有，看單字適不適合）：
```html
<h3><b>字根：XXX（來源語言＋本意）</b></h3>
<ul>
  <li><div><b>來源：</b> 源自[拉丁語/古英語/...]<i>原型</i>，意為「...」。</div></li>
  <li><div><b>核心語意：</b> ...</div></li>
  <li><div><b>同源聯想：</b> 同根詞 [related1], [related2] ...</div></li>
</ul>

<h3><b>字尾：-XXX</b></h3>
<ul>
  <li><div><b>功能：</b> [名詞/形容詞/動詞]字尾，表示「...」</div></li>
  <li><div><b>相似詞：</b> <i>example1</i>, <i>example2</i></div></li>
</ul>

<blockquote>
  <div><b>結構邏輯：</b> X (意義) + Y (意義) = 「合起來的意義」。</div>
</blockquote>
```

如果是非拉丁系字根（古英語、希臘語、複合詞），就照單字本身結構講 — 例如 `kneeling = knee + l + ing`。

如果字源真的很冷門查不到，至少給「核心字義關聯」或「容易記憶的故事」。**不要硬掰假字源**。

### 7. 例句（rich HTML，多個用法）
給 2-3 個例句，涵蓋這個字的主要用法。

結構：
```html
<h3><b>用法一：[詞性 + 情境]</b></h3>
<blockquote>
  <div><b>[英文例句]</b>（[中文翻譯]）</div>
</blockquote>

<h3><b>用法二：[詞性 + 情境]</b></h3>
<blockquote>
  <div><b>[英文例句]</b>（[中文翻譯]）</div>
</blockquote>
```

例句要：
- 是 TOEIC / 商務 / 日常會用到的句型，**不要文學或學術冷僻句**
- 完整句子（不是片語）
- 中文翻譯放小括弧 `（...）` 在英文後面
- 英文用 `<b>` 加粗（深色背景下藍色強調 .english 不適用這欄，所以用 b）

## 如何呼叫 Add-AnkiCard

每個 PowerShell tool call 是新 shell，先 dot-source：

```powershell
. "$env:USERPROFILE\.claude\skills\anki-toeic-add\scripts\Add-AnkiCard.ps1"

Add-AnkiCard `
  -Chinese  '行人' `
  -English  'pedestrian' `
  -KK       '/pəˈdɛstrɪən/' `
  -PartOfSpeech '作名詞：行人&nbsp;&nbsp;作形容詞：行人的 / 徒步的' `
  -Etymology @'
<h3><b>字根：Ped-（拉丁語「腳」）</b></h3>
<ul><li><div>源自拉丁語 <i>pes / pedis</i>，意為「腳」(foot)。</div></li></ul>
...
'@ `
  -Examples @'
<h3><b>用法一：作名詞（行人）</b></h3>
<blockquote><div><b>The bridge ensures the safety of pedestrians.</b>（這座橋確保行人的安全。）</div></blockquote>
...
'@
```

加 `-PronunNote` 只有在有 gotcha 時：
```powershell
Add-AnkiCard ... -PronunNote '<b>Silent K：</b>字首 K 不發音。'
```

## Audio 欄位 — 自動產生，不要手動傳

`Add-AnkiCard` 預設會自動：
1. 從 `-English` 參數拿單字（先把 `<b>` 等 HTML 標籤剝掉）
2. 用 `uvx edge-tts --voice en-US-AvaNeural` 產 mp3
3. 透過 AnkiConnect `storeMediaFile` 上傳到 Anki 媒體庫
4. 把 `[sound:anki_toeic_<slug>.mp3]` 寫進 Audio 欄位

所以**不需要手動傳 `-AudioTag`**。如果剛好你已經有現成的 sound tag（少見），可以傳 `-AudioTag '[sound:custom.mp3]'` 覆寫。

如果想完全跳過音檔（例如離線、edge-tts 暫時不能用、或測試），加 `-SkipAudio` 旗標。

**檔名規則**：`anki_toeic_<lowercase-alphanumeric-only>.mp3`（如 `anki_toeic_pedestrian.mp3`、`anki_toeic_kneeling.mp3`）。重複呼叫同字會直接覆蓋舊檔，不會留垃圾。

**為什麼不用 `{{tts}}`**：AnkiMobile (iOS) 預設聲音沙啞、跨裝置設定地獄；預生成 mp3 走到哪聽到哪都好聽。中文 TTS 因為使用者看中文不用聽，所以 Card 1 正面還是用 `{{tts zh_TW:中文}}` 省空間。

多個字直接連續呼叫（每個一行 dot-source 不必重複）：
```powershell
. "$env:USERPROFILE\.claude\skills\anki-toeic-add\scripts\Add-AnkiCard.ps1"
Add-AnkiCard -Chinese '...' -English 'word1' ...
Add-AnkiCard -Chinese '...' -English 'word2' ...
```

回傳 `[PSCustomObject]@{ noteId = ...; word = ... }`，把這些蒐集起來報告。

## 查重的具體做法

加之前先檢查：
```powershell
$body = '{"action":"findNotes","version":6,"params":{"query":"deck:TOEIC English:pedestrian"}}'
$r = Invoke-RestMethod -Uri http://127.0.0.1:8765 -Method Post -Body $body -ContentType 'application/json'
if ($r.result.Count -gt 0) { "duplicate" } else { "new" }
```

查到重複的就跳過、回報「已存在於 TOEIC，略過：word」，不要覆蓋現有 note。

如果使用者明確說「重做」「覆蓋」「更新解說」，那才用 `updateNoteFields` 改現有 note。

## 報告格式

做完回報用這種格式：

```
新增到 TOEIC：
  ✅ pedestrian (noteId 1778897555953)
  ✅ kneeling   (noteId 1778898708184)
  ⏭️  garage   (已存在於 TOEIC，跳過)
  ❌ asdfqwer  (Anki 拒絕：無法解析為合法單字)
☁️ 已同步到 AnkiWeb
```

成功的給 noteId，方便使用者之後想改的時候可以引用。最後一行是 sync 結果（`☁️ 已同步` 或 `⚠️ 同步失敗：原因`）；如果整批 0 張成功新增，就略過 sync 行。

## 邊角情況

- **Anki 沒開**：`Invoke-RestMethod` 會丟「無法連線」。請使用者開 Anki，等他說 OK 再重試
- **AnkiConnect 沒裝**：連得上 :8765 但回 404/HTML — 引導使用者裝 add-on `2055492159`
- **使用者丟一段文章請你挑生字**：先列出你建議的 5-10 個 TOEIC 等級生字給他過目，確認後再批次加（這是少數需要先確認的情境，因為「挑哪些字」是判斷題）
- **使用者只給單字、沒給其他資訊**：不要問他要中文翻譯什麼的 — 自己查、自己寫，這就是 skill 的價值。寫不出來才停下來問
- **單字明顯不是 TOEIC 範圍**（醫學術語、量子物理術語、罕用古詞）：照樣加，但可以順帶提一句「這字在 TOEIC 比較少見，要不要換一個」

## CSS / 模板已套好

新加的卡會自動套這套樣式（黑底、藍英文、黃 KK、左對齊解說、blockquote 深底）。**不要在欄位內容裡寫 `<style>` 或 `<font color>`**，會撞模板 CSS。如果使用者要改樣式，改 model styling 不是改個別 note。
