# gputop

A top-like GPU monitor for the Windows console. It is a single PowerShell script that reads the GPU performance counters built into Windows, so it needs no extra install and works with AMD, Intel and NVIDIA GPUs. I made it because Windows has no nvidia-smi equivalent for AMD GPUs. The rest of this README is in Japanese.

Windowsのコンソールで動く、top風のGPUモニターです。WindowsのAMD GPUには`nvidia-smi`のようなコマンドがないので作りました。Windows標準のGPUパフォーマンスカウンターを読むPowerShellスクリプト1本で、追加のインストールは要りません。AMD、Intel、NVIDIAのどのGPUでも同じ画面で確認できます。

```
gputop   2026-10-05 01:10:39   refresh 1s   press q to quit

GPU 0  AMD Radeon RX 9070 XT
  Util   [|||||||||||||||||||||||||||   ]  91.2 %   busiest engine Compute_0
  VRAM   [||||||||||||||||||            ]  59.4 %   9,728 / 16,384 MB
  Shared 300 MB
  Engine Compute_0 91.2 %   3D 42.5 %

  GPU     PID  NAME                      GPU %  ENGINE               VRAM MB
    0    4321  ollama                     91.2  Compute_0              9,000
    0     436  pwsh                       12.5  3D                       400
```

上の画面は模擬データによる表示例です。

## 動作要件

| 項目 | 内容 |
|---|---|
| OS | Windows 10 バージョン1709以降、またはWindows 11 |
| PowerShell | Windows PowerShell 5.1、またはPowerShell 7 |
| GPU | メーカーを問いません |
| 権限 | 管理者権限は不要の想定です |
| 追加インストール | 不要です |

## 入手方法

リポジトリをクローンします。

```powershell
git clone https://github.com/ueponx/gputop.git
cd gputop
```

スクリプト1本だけあれば動くので、次のように直接ダウンロードしてもかまいません。

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ueponx/gputop/main/gputop.ps1 -OutFile gputop.ps1
```

## 起動方法

`gputop.ps1`のあるフォルダーでPowerShellを開いて実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\gputop.ps1
```

PowerShell 7を使う場合は`powershell`を`pwsh`に読み替えてください。

Windows 10やWindows 11の既定の実行ポリシーではスクリプトを直接実行できないため、上のように`-ExecutionPolicy Bypass`を付けて起動します。実行ポリシーを`RemoteSigned`にしている環境では`.\gputop.ps1`だけで起動できます。ブラウザーでダウンロードしたファイルがブロックされる場合は、次のコマンドで解除してください。

```powershell
Unblock-File .\gputop.ps1
```

終了するにはqキーかEscキーを押します。Ctrl+Cでも終了でき、カーソル表示は元に戻ります。

## オプション

| オプション | 既定値 | 指定できる範囲 | 内容 |
|---|---|---|---|
| `-Interval` | 1 | 1から60 | 更新間隔を秒で指定します |
| `-Top` | 10 | 0から50 | 画面に表示するプロセス数です。0でプロセス表を隠します |
| `-Once` | なし | | 1回だけ取得して終了します |
| `-Count` | 0 | 0から1000000 | 指定した回数だけ取得して終了します。0は無制限です |
| `-Gpu` | すべて | GPUの番号 | 対象のGPUを絞ります。`-Gpu 0`や`-Gpu 0,1`のように指定します |
| `-All` | なし | | ソフトウェアアダプターや名前のないアダプターも表示します |
| `-LogCsv` | なし | ファイルパス | GPUごとの値を更新のたびにCSVへ追記します |
| `-LogProcessCsv` | なし | ファイルパス | プロセスごとの値を更新のたびにCSVへ追記します |

スクリプト向けの出力を選ぶオプションです。詳しくは次の節で説明します。

| オプション | 指定する値 | 内容 |
|---|---|---|
| `-Query` | 項目名 | GPUごとの項目を選んでCSVで出力します |
| `-QueryProcess` | 項目名 | プロセスごとの項目を選んでCSVで出力します |
| `-Json` | | GPUとプロセスをまとめてJSONで出力します |
| `-Stream` | `gpu`か`process` | 1サンプル1行で流し続けます |
| `-Loop` | | `-Query`、`-QueryProcess`、`-Json`を更新間隔ごとに繰り返します |
| `-NoHeader` | | `-Query`、`-QueryProcess`、`-Stream`のヘッダー行を省きます |

使用例です。

```powershell
# 2秒間隔で、プロセスを15件まで表示する
.\gputop.ps1 -Interval 2 -Top 15

# 画面に表示しながら、GPUとプロセスの両方をCSVに記録する
.\gputop.ps1 -LogCsv gpu_log.csv -LogProcessCsv proc_log.csv

# 1回分だけ画面に出力する
.\gputop.ps1 -Once

# GPU 0だけを表示する
.\gputop.ps1 -Gpu 0
```

スクリプト内のヘルプは`Get-Help .\gputop.ps1 -Full`で読めます。

## スクリプトから使う

画面表示のほかに、スクリプトから扱いやすい出力モードが4つあります。結果は標準出力に出るので、変数に受けたりファイルにリダイレクトしたりできます。4つのうち同時に指定できるのは1つだけです。

`nvidia-smi`との対応はおおよそ次のとおりです。

| nvidia-smi | gputop |
|---|---|
| `--query-gpu=... --format=csv` | `-Query ...` |
| `--query-compute-apps=... --format=csv` | `-QueryProcess ...` |
| `-x` | `-Json` |
| `dmon` | `-Stream gpu` |
| `pmon` | `-Stream process` |
| `-i 0` | `-Gpu 0` |
| `-l 1` | `-Loop -Interval 1` |

### 項目を選んでCSVで出す

`-Query`にGPUごとの項目名をカンマ区切りで渡します。

```powershell
.\gputop.ps1 -Query util_pct,vram_used_mb
```

```
util_pct,vram_used_mb
91.2,9728
```

`-Query`で指定できる項目です。

| 項目 | 内容 |
|---|---|
| `timestamp` | 取得時刻です（`yyyy-MM-dd HH:mm:ss`形式） |
| `gpu` | GPUの番号です |
| `name` | アダプター名です |
| `luid` | Windowsがアダプターに割り当てている識別子です。再起動で変わります |
| `util_pct` | GPU使用率です（%） |
| `busiest_engine` | 最も忙しいエンジンの種類です。アイドル時は空になります |
| `vram_used_mb` | 専用ビデオメモリの使用量です（MB） |
| `vram_total_mb` | 専用ビデオメモリの総量です（MB）。不明な場合は0です |
| `vram_pct` | 専用ビデオメモリの使用率です（%）。総量が不明な場合は空になります |
| `shared_used_mb` | 共有メモリの使用量です（MB） |

`-QueryProcess`にはプロセスごとの項目名を渡します。

```powershell
.\gputop.ps1 -QueryProcess pid,name,util_pct,vram_used_mb
```

```
pid,name,util_pct,vram_used_mb
4321,"ollama",91.2,9000
436,"pwsh",12.5,400
```

`-QueryProcess`で指定できる項目です。

| 項目 | 内容 |
|---|---|
| `timestamp` | 取得時刻です |
| `gpu` | そのプロセスが使っているGPUの番号です |
| `pid` | プロセスIDです |
| `name` | プロセス名です。取得できない場合は`?`になります |
| `util_pct` | そのプロセスのGPU使用率です（%） |
| `engine` | そのプロセスが最も使っているエンジンの種類です |
| `vram_used_mb` | そのプロセスの専用ビデオメモリ使用量です（MB） |

どちらも1回出力して終了します。`-Loop`を付けると更新間隔ごとに繰り返し、ヘッダー行は最初の1回だけ出します。回数を決めたいときは`-Count`を使います。

`-Top`を指定しないかぎり、動作中のプロセスをすべて出力します。これは`-Json`と`-Stream process`でも同じです。

値を変数に受ける例です。

```powershell
$line = .\gputop.ps1 -Query util_pct,vram_used_mb -NoHeader -Gpu 0
$util, $vram = $line -split ','
```

### JSONで出す

`-Json`を付けると、GPUとプロセスの情報をまとめて出力します。

```powershell
.\gputop.ps1 -Json
```

```json
{
  "timestamp": "2026-10-06T13:56:15+09:00",
  "source": "counter",
  "gpus": [
    {
      "gpu": 0,
      "name": "AMD Radeon RX 9070 XT",
      "luid": "luid_0x00000000_0x0000d3a5",
      "util_pct": 91.2,
      "busiest_engine": "Compute_0",
      "vram_used_mb": 9728,
      "vram_total_mb": 16384,
      "vram_pct": 59.4,
      "shared_used_mb": 300,
      "engines": {
        "Compute_0": 91.2,
        "3D": 42.5,
        "VideoDecode": 0.0
      }
    }
  ],
  "processes": [
    {
      "gpu": 0,
      "pid": 4321,
      "name": "ollama",
      "util_pct": 91.2,
      "engine": "Compute_0",
      "vram_used_mb": 9000
    }
  ]
}
```

`engines`にはエンジンの種類ごとの使用率がすべて入ります。`vram_pct`は総量が不明な場合に`null`になります。`source`は値の取得元で、`counter`か`cim`のどちらかです。

PowerShellではそのままオブジェクトにできます。

```powershell
$s = .\gputop.ps1 -Json | ConvertFrom-Json
$s.gpus[0].util_pct
```

`-Loop`を付けた場合は、1サンプルを1行にまとめた形式で出力し続けます。

### 流れるログとして出す

`-Stream gpu`は、GPU1台につき1行を更新間隔ごとに出し続けます。

```powershell
.\gputop.ps1 -Stream gpu
```

```
#time     gpu  util%  engine              vram_mb  vram%  shared_mb
13:55:14    0   91.2  Compute_0              9728   59.4        300
13:55:15    0   90.8  Compute_0              9728   59.4        300
```

`-Stream process`は、プロセス1つにつき1行を出します。動作中のプロセスがないGPUは、値の欄が`-`の行になります。

```powershell
.\gputop.ps1 -Stream process
```

```
#time     gpu      pid  util%  engine              vram_mb  name
13:55:15    0     4321   91.2  Compute_0              9000  ollama
13:55:15    0      436   12.5  3D                      400  pwsh
```

ヘッダー行は20サンプルごとに出し直します。止めるにはCtrl+Cを押すか、あらかじめ`-Count`で回数を指定します。

### 終了コード

スクリプト向けの出力モードでは、結果を終了コードで判定できます。エラーの内容は標準エラー出力に出ます。

| 終了コード | 意味 |
|---|---|
| 0 | 出力できました |
| 1 | GPUの情報を取得できませんでした |
| 2 | 引数の指定が正しくありません |

画面表示では、GPUの情報を取得できない場合も画面に案内を出すだけで、終了コードは0のままです。

## 画面の見方

### GPUごとの表示

| 行 | 内容 |
|---|---|
| `GPU n` | 通し番号とアダプター名です |
| `Util` | GPU使用率です。右側の`busiest engine`は最も忙しいエンジンの種類です |
| `VRAM` | 専用ビデオメモリの使用率、使用量、総量です |
| `Shared` | 共有メモリ（メインメモリから借りている分）の使用量です |
| `Engine` | エンジンの種類ごとの使用率です。高い順に4種類まで表示します |

バーの色と`Engine`行の数値の色は負荷に応じて変わります。50%未満は緑、50%以上は黄、80%以上は赤です。

### プロセス表

| 列 | 内容 |
|---|---|
| `GPU` | そのプロセスが使っているGPUの番号です |
| `PID` | プロセスIDです |
| `NAME` | プロセス名です。取得できない場合は`?`になります |
| `GPU %` | そのプロセスのGPU使用率です |
| `ENGINE` | そのプロセスが最も使っているエンジンの種類です |
| `VRAM MB` | そのプロセスの専用ビデオメモリ使用量です |

表に載るのは、GPU使用率が0.1%以上か、専用ビデオメモリを1MB以上使っているプロセスです。GPU使用率の高い順、同じ場合はVRAM使用量の多い順に並びます。

### エンジンの種類

GPUは用途別の「エンジン」に分かれており、名前はドライバーが決めます。代表的なものは次のとおりです。

| 名前 | 用途 |
|---|---|
| `3D` | 描画全般です。ゲームやデスクトップの表示がここに出ます |
| `Compute_0`など | 汎用計算です。LLM推論などの負荷は主にここに出ます |
| `Cuda` | NVIDIAのGPUでの汎用計算です |
| `VideoDecode` | 動画のデコードです |
| `VideoEncode` | 動画のエンコードです |
| `Copy` | メモリ転送です |

## 使用率の算出方法

タスクマネージャーと同じ考え方で、最も忙しいエンジンの値をそのGPUの使用率としています。

1. エンジンごとに、全プロセスの使用率を合計します。
2. その中で最大のものをGPU使用率とします。
3. 100%を超えた場合は100%に丸めます。

プロセスごとの使用率も同様で、そのプロセスが使っているエンジンのうち最大の値です。全エンジンを単純に合算する方式と違い、Computeだけが動く負荷でも実態に近い値になります。

## CSVログ

画面表示やスクリプト向けの出力と同時に、CSVファイルへ記録を残せます。

### GPUごとのログ

`-LogCsv`を付けると、更新のたびにGPU1台につき1行を追記します。ファイルがなければヘッダー行付きで新規作成し、すでにあれば末尾に追記します。文字コードはUTF-8です。

| 列 | 内容 |
|---|---|
| `timestamp` | 記録時刻です（`yyyy-MM-dd HH:mm:ss`形式） |
| `gpu` | GPUの番号です |
| `name` | アダプター名です |
| `util_pct` | GPU使用率です（%） |
| `busiest_engine` | 最も忙しいエンジンの種類です。アイドル時は空になります |
| `vram_used_mb` | 専用ビデオメモリの使用量です（MB） |
| `vram_total_mb` | 専用ビデオメモリの総量です（MB）。不明な場合は0です |
| `shared_used_mb` | 共有メモリの使用量です（MB） |

出力例です。

```
timestamp,gpu,name,util_pct,busiest_engine,vram_used_mb,vram_total_mb,shared_used_mb
2026-10-05 01:10:27,0,"AMD Radeon RX 9070 XT",91.2,Compute_0,9728,16384,300
```

### プロセスごとのログ

`-LogProcessCsv`を付けると、更新のたびに動作中のプロセス1つにつき1行を追記します。`-Top`の値にかかわらず、動作中のプロセスをすべて記録します。

| 列 | 内容 |
|---|---|
| `timestamp` | 記録時刻です |
| `gpu` | そのプロセスが使っているGPUの番号です |
| `pid` | プロセスIDです |
| `name` | プロセス名です |
| `util_pct` | そのプロセスのGPU使用率です（%） |
| `engine` | そのプロセスが最も使っているエンジンの種類です |
| `vram_used_mb` | そのプロセスの専用ビデオメモリ使用量です（MB） |

出力例です。

```
timestamp,gpu,pid,name,util_pct,engine,vram_used_mb
2026-10-05 01:10:27,0,4321,"ollama",91.2,Compute_0,9000
2026-10-05 01:10:27,0,436,"pwsh",12.5,3D,400
```

`-Gpu`で対象を絞っている場合は、どちらのログもそのGPUの分だけになります。

## GPU構成ごとの挙動

| 構成 | 挙動 |
|---|---|
| AMDのGPU | そのまま表示されます |
| NVIDIAのGPU | そのまま表示されます。エンジン名は`Cuda`などNVIDIA側の名前になります |
| Intelなどの内蔵GPU | 動きますが、専用VRAMが小さいため`VRAM`のバーは参考になりません。`Shared`の行が実際の使用量に近くなります |
| 内蔵GPUと外付けGPUの両方 | `GPU 0`と`GPU 1`として並びます。どちらを使っているかはプロセス表の`GPU`列で分かります |
| GPUなし、または仮想マシン | 既定では`No hardware GPU was found.`という案内が出ます。`-All`を付けるとソフトウェアアダプターが表示されます |

## 制限事項

- 読み取り専用です。電力上限の設定など、GPUの設定を変える機能はありません。
- 温度、消費電力、ファン回転数、クロックは表示できません。Windows標準のカウンターに含まれていないためです。必要な場合はAMD Software Adrenalin EditionやHWiNFOを併用してください。
- 値の出どころはタスクマネージャーと同じです。メーカー製ツールの値とは算出方法が異なるため、数値が一致しないことがあります。
- ウィンドウが小さいと、収まらない行と桁は切り捨てて表示します。
- すでに終了したプロセスや、名前を取得できないプロセスは`NAME`が`?`になります。

## 動作確認の状況

現時点で確認できているのは次の範囲です。

- PowerShell 7.4での構文チェック
- 模擬カウンターデータを使った集計、画面表示、CSV出力、qキーでの終了
- 模擬カウンターデータを使った`-Query`、`-QueryProcess`、`-Json`、`-Stream`、`-Gpu`、`-Count`の出力と終了コード（CSVとJSONは別のプログラムで読み直して確認）
- カウンターが取得できない場合のWMIへの切り替えと、どちらも取得できない場合の案内表示
- 実機のWindowsでの起動と、`-Json`によるGPU使用率の取得

次の点は未確認です。

- 実機での画面表示と、`-Json`以外の出力モード
- Windows PowerShell 5.1とPowerShell 7のそれぞれでの動作
- レジストリからのアダプター名とVRAM総量の取得

## トラブルシューティング

### スクリプトの実行がブロックされる

エラーの文言によって原因と対処が異なります。

- 「デジタル署名されていません」という趣旨のエラーの場合は、実行ポリシーが`RemoteSigned`で、ダウンロードしたファイルに付く「インターネットから来た」という印が原因です。ブラウザーで直接ダウンロードした場合のほか、ZIPでダウンロードしてエクスプローラーで展開した場合も印が付きます。次のコマンドで印を外すと、以後は`.\gputop.ps1`だけで起動できます。

```powershell
Unblock-File .\gputop.ps1
```

- 「このシステムではスクリプトの実行が無効になっている」という趣旨のエラーの場合は、実行ポリシーが既定の`Restricted`のままです。起動方法の節にある`-ExecutionPolicy Bypass`付きのコマンドで起動してください。

どちらの場合も、`Get-ExecutionPolicy -List`で現在の実行ポリシーを確認できます。

### No hardware GPU was found. と表示される

ハードウェアGPUが見つからない場合です。仮想マシンなどで起こります。`-All`を付けるとソフトウェアアダプターを含めて表示します。

### No GPU counter data was returned. と表示される

GPUカウンター自体が取得できない場合です。次のコマンドで`GPU Engine`などのカウンターセットが一覧に出るか確認してください。

```powershell
Get-Counter -ListSet 'GPU*'
```

### No GPU matches -Gpu と表示される

`-Gpu`で指定した番号のGPUがない場合です。番号は画面に`GPU 0`、`GPU 1`と表示される数字で、`-Gpu`を付けずに実行すると確認できます。

### アダプター名が Unknown adapter になる

カウンター上のアダプターとレジストリの情報を対応付けられなかった場合です。使用率やメモリ使用量の値には影響しません。

### VRAMが total size unknown になる

VRAMの総量を取得できなかった場合です。使用量は表示されますが、使用率のバーは出ません。

### ヘッダーに source WMI と表示される

`Get-Counter`でカウンターを取得できず、WMI経由の取得に切り替わっています。表示内容は同じですが、使用率は整数に丸められます。

## 仕組み

情報の取得元は次のとおりです。

| 情報 | 取得元 |
|---|---|
| GPU使用率 | カウンター `\GPU Engine(*)\Utilization Percentage` |
| GPUごとのメモリ | カウンター `\GPU Adapter Memory(*)\Dedicated Usage` と `Shared Usage` |
| プロセスごとのメモリ | カウンター `\GPU Process Memory(*)\Dedicated Usage` |
| アダプター名とVRAM総量 | レジストリ `HKLM\SOFTWARE\Microsoft\DirectX` |
| 同上の予備 | レジストリのディスプレイアダプタークラス（上で取得できなかった場合に使います） |
| プロセス名 | `Get-Process` |

カウンターを取得できなかった場合は、WMIの`Win32_PerfFormattedData_GPUPerformanceCounters_`で始まる3つのクラスに切り替えます。WMIのクラス名はOSの表示言語に依存しないため、言語設定が原因でカウンターを引けない環境への備えになります。

既定では`Microsoft Basic Render Driver`と、名前がなく動作もしていないアダプターを隠します。`-All`を付けるとこれらも表示します。

## ライセンス

MIT Licenseです。詳細は[LICENSE](LICENSE)を参照してください。
