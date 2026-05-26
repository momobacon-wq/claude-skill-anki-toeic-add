---
name: anki-toeic-add
description: 透過 AnkiConnect API（localhost:8765）新增英文單字卡到使用者的 Anki TOEIC 牌組（note type：英文單字，11 個欄位 — 含多益實戰強化欄位）。**也是 `/toeic` 斜線指令的完整實作**（`/toeic <英文單字>` 會走這個 skill）。Trigger 詞包括："加單字到 Anki"、"幫我加 X 到 TOEIC"、"建單字卡 X"、"新增 Anki 卡片"、"TOEIC 加卡 X"、"幫我把這幾個單字做成 anki"、"add X to my Anki"、"make a flashcard for X"、"create Anki card for word"。使用者可能只丟單字列表、句子裡的生字、或一段英文文章請你挑生字。Skill 會自動產生中文翻譯、KK 音標、詞性、字根字首拆解、例句、常用搭配（Part 5/6 核心）、同義反義字（Part 5 替換題）、多益情境標籤（Part 分布+商業情境），並用 edge-tts 的 AvaNeural 聲音產生英文發音 mp3 嵌入卡片（不靠 Anki 內建 TTS，跨裝置都聽得到 Ava 級的聲音），最後呼叫 AnkiConnect 推入 TOEIC 牌組。預設不重複加同字、不問確認、不要 dry-run。
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
- Note type：`英文單字`（**11 欄位**，順序：中文 / English / KK音標 / 發音說明 / 詞性 / 解說 / 例句 / **常用搭配** / **同義字反義** / **多益情境** / Audio）— 後 3 欄是多益實戰強化欄位（2026-05 加入）
- 2 張卡的模板（Card 1 中→英、Card 2 英→中）— **英文發音改用嵌入式 mp3**（`{{Audio}}`），不再用 `{{tts en_US:English}}`。原因：AnkiMobile (iOS) 的 TTS 預設聲音沙啞，預生成 mp3 跨裝置都好聽
- 中文那行還是 `{{tts zh_TW:中文}}`（中文不靠聽、留 TTS 省空間）
- `uvx`(從 `uv` 來)在 PATH 上,用來免安裝跑 edge-tts;若 `uvx` 不在,腳本會自動 fallback 到 `python -m edge_tts`(需先 `pip install --user edge-tts`)
- PowerShell 函式 `Add-AnkiCard`、`New-AnkiTtsAudio`、`Test-AnkiCardExists`、`Test-AnkiConnect`、`Start-AnkiIfNotRunning` 在 `scripts/Add-AnkiCard.ps1`

## 觸發後的執行流程

1. **確保 Anki 在跑（自動開）**：dot-source `scripts/Add-AnkiCard.ps1` 後呼叫 `Start-AnkiIfNotRunning`。它會：
   - 先試 AnkiConnect `version`；若回應就直接 return（不重複開）
   - 沒回應就自動找 `anki.exe`（`$env:LOCALAPPDATA\Programs\Anki\anki.exe` 等標準路徑），`Start-Process` 開起來
   - 然後 poll AnkiConnect 每 2 秒一次、最多 60 秒，等他上線
   - 回傳 `{ ok, launched, version, waitedSeconds, error }`

   **不要**問使用者「能幫我開 Anki 嗎」、**不要**自己手刻 Start-Process — 直接 `Start-AnkiIfNotRunning`。
   如果 `ok=$false`（找不到 anki.exe 或 60 秒還沒上線）才停下來把 `error` 顯示給使用者。
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

### 7. 例句（rich HTML，**每個用法對應一個多益題型**）

例句不再寫「抽象造句」— 每個用法直接寫成**多益某個 Part 會出現的真實題型 / 文體**，並在用法標題後面用 `📊 Part X` 標明。這樣使用者複習時就在練「實戰辨識」。

#### 多益題型對應規則（按單字用法數量分配）

| 單字用法數 | 例句配法 |
|---|---|
| **3 個用法** | 用法一→ **Part 5 cloze 題**；用法二→ **Part 4 獨白 / Part 3 對話**；用法三→ **Part 7 文件 (email/告示/廣告)** |
| **2 個用法** | 用法一→ **Part 5 cloze 題**；用法二→ **Part 7 文件** |
| **1 個用法 (主要動詞/形容詞)** | 寫成 **Part 7 商業 email / 告示**，1 段足矣 |
| **1 個用法 (具象名詞/動作詞,如 kneeling、garage)** | 寫成 **Part 1 圖片描述風** (`In the picture, ...`) |

#### Part 5 cloze 題範本（用法一通常用這個）

留一個 `___` 空格 + 4 個選項 (1 對 3 錯,錯的要是**有意義的陷阱字** — 拼字接近、詞性相同、或本欄「同義字反義」列的混淆字),附答案解析。

```html
<h3><b>用法一：[詞性 + 情境] — 📊 Part 5 cloze 題型</b></h3>
<blockquote>
  <div>[題幹英文,空格用 ___]</div>
  <div><b>(A)</b> [選項1] &nbsp;<b>(B)</b> [選項2] &nbsp;<b>(C)</b> [選項3] &nbsp;<b>(D)</b> [選項4]</div>
  <div><b>答案：</b> ([字母]) [正解] — [一句話解析:為什麼這個對、其他陷阱選項哪裡不合]</div>
  <div><b>中譯：</b> [完整題幹的中文翻譯]</div>
</blockquote>
```

#### Part 4 / Part 3 聽力風範本（用法二常用）

寫成會議致詞、機場廣播、客服對話、公司公告等口語段落,用引號包整段標示「這是聽得到的句子」。

```html
<h3><b>用法二：[詞性 + 情境] — 📊 Part 4 [會議致詞/廣播/獨白] 風</b></h3>
<blockquote>
  <div><b>"[完整一段口語英文 1-3 句]"</b></div>
  <div><b>中譯：</b> 「[中文翻譯]」</div>
</blockquote>
```

#### Part 7 文件風範本（用法三常用,也適合單一用法的字）

寫成商業 email、公司告示、產品廣告、招聘啟事等書面文件片段,通常 1-2 句帶情境。

```html
<h3><b>用法三：[詞性 + 情境] — 📊 Part 7 [email/告示/廣告/招聘信] 風</b></h3>
<blockquote>
  <div><b>"[完整一段商業書面英文]"</b></div>
  <div><b>中譯：</b> [中文翻譯]</div>
</blockquote>
```

#### Part 1 圖片描述風（具象動作/物體用）

```html
<h3><b>用法：[詞性 + 情境] — 📊 Part 1 圖片描述風</b></h3>
<blockquote>
  <div><b>"In the picture, [人物 + 動作 + 場景]"</b></div>
  <div><b>中譯：</b> [中文翻譯]</div>
</blockquote>
```

#### 共通要求

- 句子是 **TOEIC 真實會出現的場景**:辦公室、會議、招聘、客訴、合約、行銷、旅遊、餐廳、維修、財務 — **不要文學/學術冷僻句**
- 中文翻譯放在英文下一行 `<b>中譯：</b>`,**不再放在英文同一行的小括弧裡**(讓 Part 5 答案解析、選項排版乾淨)
- 英文用 `<b>` 加粗
- Part 5 cloze 的陷阱選項要設計過 — **優先選用「同義字反義」欄列的混淆字**,讓兩欄互相強化記憶
- 不適合做 Part 5 cloze 的字 (例如太基礎的、太冷僻的、答案太明顯的),改用 Part 7 短段落替代,不必硬塞

### 8. 常用搭配（rich HTML，**多益 Part 5/6 核心**）
這欄是多益實戰命中率最高的一欄 — 多益詞彙題很愛考「動詞 + 名詞」、「形容詞 + 介系詞」搭配。給 **3-5 條最高頻搭配**。

結構：
```html
<h3>高頻搭配</h3>
<ul>
  <li><b>[搭配 1]</b> — [中文意思]</li>
  <li><b>[搭配 2]</b> — [中文意思]</li>
  <li><b>[搭配 3]</b> — [中文意思]</li>
</ul>
```

挑選原則：
- **動詞**：列 V + N 搭配（什麼樣的受詞最常接）— 例如 `address an issue / concerns / a problem`
- **名詞**：列 V + N 或形容詞前置詞（最常被什麼動詞用、形容詞修飾）— 例如 `reach an agreement`、`a tentative agreement`
- **形容詞**：列 Adj + N 搭配 + 後接介系詞 — 例如 `eligible for promotion`、`eligible to apply`
- **介系詞偏好**：如果這字有強制搭配介系詞，**一定要寫**（多益 Part 5 必考）— 例如 `comply with`、`adhere to`、`refrain from`

範例：
```html
<h3>高頻搭配</h3>
<ul>
  <li><b>address an issue / concerns / a problem</b> — 處理…問題</li>
  <li><b>address a meeting / audience</b> — 對…發表演說</li>
  <li><b>address sb. by name</b> — 以名字稱呼某人</li>
  <li><b>address [a letter] to sb.</b> — 把信寫給某人（注意搭 to）</li>
</ul>
```

不要寫超過 5 條，會稀釋。**冷僻搭配不寫**（要的是多益會考的)。

### 9. 同義字反義（rich HTML，**Part 5 替換題核心 + 混淆字提醒**）
這欄包三件事：① 同義字（Part 5 選項常 paraphrase 替換）、② 反義字（出在 Part 7 對比題）、③ 混淆字（拼字相近、容易被多益陷阱題坑）。

結構（不必每段都有，看單字適不適合）：
```html
<div><b>≈ Synonyms（Part 5 常見替換）：</b> [同義字 1], [同義字 2], [同義字 3]</div>
<div><b>↔ Antonyms：</b> [反義字 1], [反義字 2]</div>
<div><b>⚠ 易混淆：</b> [字 A]（[差異 1]）／[字 B]（[差異 2]）— [一句話辨識訣竅]</div>
```

挑選原則：
- **同義字 2-4 個**，挑多益真的會用來替換的詞，不要寫冷僻字
- **反義字 1-2 個**，沒有明顯反義字就省略
- **混淆字只在有實際陷阱時寫**（例如 `affect/effect`、`access/assess/address`、`accept/except`、`principal/principle`），普通字省略

範例（address）：
```html
<div><b>≈ Synonyms（Part 5 常見替換）：</b> tackle, handle, deal with, resolve, attend to</div>
<div><b>↔ Antonyms：</b> ignore, neglect, overlook, disregard</div>
<div><b>⚠ 易混淆：</b> address（處理 / 演說）／access（進入、access to）／assess（評估）— 三字差一兩個字母，多益 Part 5 常設陷阱選項。</div>
```

範例（簡單名詞，例如 garage，沒有複雜反義字也沒有混淆字）：
```html
<div><b>≈ Synonyms：</b> auto repair shop, service station</div>
```

### 10. 多益情境（rich HTML，**標籤式元資訊**）
這欄是「這字在多益會怎麼考、考在哪」的標籤式說明。**短而精**，不要長篇大論。

結構：
```html
<div><b>📊 高頻 Part：</b> [Part X (題型描述), Part Y (題型描述)]</div>
<div><b>🏢 商業情境：</b> [情境 1]、[情境 2]、[情境 3]</div>
<div><b>📈 等級：</b> TOEIC [600+ / 700+ / 800+ / 900+]（[頻率描述]）</div>
```

填寫指引：
- **📊 高頻 Part**：寫多益常出現的 Part + 該 Part 的常見題型（Part 1 圖片描述 / Part 2 問答 / Part 3-4 簡短對話獨白 / Part 5 詞彙文法 / Part 6 段落填空 / Part 7 閱讀)
- **🏢 商業情境**：寫 2-4 個多益常見的商業情境分類 — 辦公室通訊 / 招聘錄取 / 會議報告 / 客戶服務 / 行銷廣告 / 合約法務 / 採購供應 / 旅遊住宿 / 餐廳訂位 / 維修保養 / 財務會計 / 人事公告
- **📈 等級**：估計這字大概在哪個分數段算高頻 — 600+（中高頻，基本常見字）/ 700+（中等難度）/ 800+（中高難度，高分必備）/ 900+（少見高階字）

範例（address）：
```html
<div><b>📊 高頻 Part：</b> Part 5（動詞詞彙題、介系詞題）、Part 7（商業 email、客訴回覆）、Part 4（會議致詞獨白）</div>
<div><b>🏢 商業情境：</b> 客訴處理、會議致詞、招聘信開頭稱呼、解決運作問題</div>
<div><b>📈 等級：</b> TOEIC 600+（高頻多義字，必背）</div>
```

範例（kneeling，多益少見字）：
```html
<div><b>📊 高頻 Part：</b> Part 1（人物動作描述，少見但偶爾出現）</div>
<div><b>🏢 商業情境：</b> （非商業情境字）</div>
<div><b>📈 等級：</b> TOEIC 800+（罕見，Part 1 偶爾出題）</div>
```

## 如何呼叫 Add-AnkiCard

每個 PowerShell tool call 是新 shell，先 dot-source、再確保 Anki 在跑、最後加卡：

```powershell
. "$env:USERPROFILE\.claude\skills\anki-toeic-add\scripts\Add-AnkiCard.ps1"

# 確保 Anki 桌面有開（沒開就自動開、等 AnkiConnect 上線）
$boot = Start-AnkiIfNotRunning
if (-not $boot.ok) { throw "Anki not ready: $($boot.error)" }

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
<h3><b>用法：作名詞（行人）— 📊 Part 1 圖片描述風</b></h3>
<blockquote>
  <div><b>"In the picture, several pedestrians are waiting at the crosswalk."</b></div>
  <div><b>中譯：</b> 圖中,幾位行人正在斑馬線旁等候。</div>
</blockquote>
...
'@ `
  -Collocations @'
<h3>高頻搭配</h3>
<ul>
  <li><b>pedestrian crossing / crosswalk</b> — 行人穿越道</li>
  <li><b>pedestrian zone / area</b> — 行人徒步區</li>
  <li><b>pedestrian traffic</b> — 行人流量</li>
</ul>
'@ `
  -Synonyms @'
<div><b>≈ Synonyms：</b> walker, foot passenger</div>
<div><b>↔ Antonyms：</b> driver, motorist</div>
'@ `
  -TOEICContext @'
<div><b>📊 高頻 Part：</b> Part 1（街景描述）、Part 7（交通告示、市政公告）</div>
<div><b>🏢 商業情境：</b> 城市規劃、交通安全告示、活動封街通知</div>
<div><b>📈 等級：</b> TOEIC 600+（Part 1 圖片題高頻）</div>
'@
```

**3 個新欄位都必填**（mandatory 參數）— 不要傳空字串或忽略。即使單字本身比較沒有商業情境（例如 kneeling），也要在 `-TOEICContext` 老實寫「非商業情境字」並標等級。

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

- **Anki 沒開**：交給 `Start-AnkiIfNotRunning` 自動開 + 等 AnkiConnect 上線（最多 60 秒）。只有當回傳 `ok=$false` 才停下來把 `error` 告訴使用者（通常是 anki.exe 找不到 → 沒裝 Anki 桌面，或裝在非標準路徑 → 用 `-ExtraPaths` 補）
- **AnkiConnect 沒裝**：連得上 :8765 但回 404/HTML — 引導使用者裝 add-on `2055492159`
- **使用者丟一段文章請你挑生字**：先列出你建議的 5-10 個 TOEIC 等級生字給他過目，確認後再批次加（這是少數需要先確認的情境，因為「挑哪些字」是判斷題）
- **使用者只給單字、沒給其他資訊**：不要問他要中文翻譯什麼的 — 自己查、自己寫，這就是 skill 的價值。寫不出來才停下來問
- **單字明顯不是 TOEIC 範圍**（醫學術語、量子物理術語、罕用古詞）：照樣加，但可以順帶提一句「這字在 TOEIC 比較少見，要不要換一個」

## CSS / 模板已套好

新加的卡會自動套這套樣式（黑底、藍英文、黃 KK、左對齊解說、blockquote 深底）。**不要在欄位內容裡寫 `<style>` 或 `<font color>`**，會撞模板 CSS。如果使用者要改樣式，改 model styling 不是改個別 note。
