# Qwen on Foundry Managed compute

小型 Qwen を **Microsoft Foundry Managed compute (preview)** の専用 GPU 上にホストし、Python CLI から日本語で推論するサンプルです。基盤、RBAC、モデルデプロイの作成・更新・削除を Terraform で管理します。

**既定では GPU を作成しません。** 最初に Foundry の基盤だけを作り、モデル・テンプレート・クォータ・料金を確認してから GPU デプロイを有効化します。

**2026-10-20 に実機確認済みです。** East US 2 の Foundry アカウントに Qwen3-0.6B v6 を `GlobalManagedCompute`、A100 80 GB 1 基でデプロイし、`Succeeded` と Entra ID 認証の Python CLI による日本語応答を確認しました。再 plan も差分なしです。これは応答の品質評価や、別環境でのモデル利用可否・クォータを保証するものではありません。

## 対象と構成

新しい Foundry の `GlobalManagedCompute` が対象です。Foundry (classic)、Azure ML Managed Online Endpoint、AKS、GPU VM、自作 vLLM コンテナーは使用しません。`azureml://` 形式のアセット URI を参照しますが、Azure ML ワークスペースを作る構成ではありません。

| 対象 | 管理方法 |
| --- | --- |
| 専用リソースグループ | AzureRM |
| Foundry アカウント | AzureRM、`AIServices`、プロジェクト管理有効 |
| Foundry プロジェクト | AzAPI、システム割り当てマネージド ID |
| 推論ユーザー・プロジェクト ID の権限 | アカウントスコープの Foundry User |
| Qwen の GPU デプロイ | AzAPI、アカウント直下の `managedComputeDeployments` |
| 推論 | OpenAI Python SDK、Entra ID、パブリックエンドポイント |

アカウントの API キー認証は無効です。Terraform でキーを取得・出力せず、CLI もキー認証にフォールバックしません。CLI は Azure public cloud のアカウント用 URL のみを受け付け、トークンを別のホストへ送らないようにしています。

実装は `infra/`、推論 CLI は `scripts/chat.py`、単体テストは `tests/` にあります。Web UI、会話履歴、ストリーミング、CI/CD、本番運用向けの監視・閉域化は含みません。

### API とバージョン

- Terraform: 1.11 以上、2.0 未満。
- AzureRM: 5.10.x。AzAPI: 2.13.x。実際の選択は `infra/.terraform.lock.hcl` に固定します。
- プロジェクト: `Microsoft.CognitiveServices/accounts/projects@2026-03-01`。
- モデル: `Microsoft.CognitiveServices/accounts/managedComputeDeployments@2026-05-15-preview`。

モデル API は AzAPI 2.13.0 が組み込みスキーマで検証できるバージョンを採用しています。より新しい `2026-07-15-preview` は同プロバイダーのスキーマに未収録のため使用していません。`schema_validation_enabled` は無効化していません。

## 前提条件

- [Terraform CLI](https://developer.hashicorp.com/terraform/install)、[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)、Python 3.11 以上。
- Azure public cloud のサブスクリプション。基盤リージョンで Foundry と Managed compute を利用できること。
- リソースグループと配下のリソースを作成する権限、および `Microsoft.Authorization/roleAssignments/write`。Contributor だけでは RBAC を割り当てられません。Owner または適切な RBAC 管理者に確認してください。
- モデル作成にはアカウントスコープの Cognitive Services Contributor または Foundry Account Owner / Foundry Owner 相当の権限。
- クォータ表示にはサブスクリプションスコープの Cognitive Services Usages Reader などが必要です。本サンプルはその権限を自動付与しません。
- GPU 作成前に、選択したアクセラレーター向けの **Managed compute 専用クォータ** が承認されていること。Azure VM の GPU クォータとは別です。

azd、Docker、Hugging Face のトークン、ローカル GPU、`azure-ai-ml` は不要です。モデルの重みや学習用データはこのフォルダーへダウンロードしません。

## 1. ローカル環境と入力を準備する

以下のコマンドはこのフォルダーをカレントディレクトリとして実行します。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt

az login
az account set --subscription "<利用するサブスクリプション ID>"
az ad signed-in-user show --query id --output tsv

cp infra/terraform.tfvars.example infra/terraform.tfvars
```

`infra/terraform.tfvars` の次の値を編集してください。

| 変数 | 内容 |
| --- | --- |
| `subscription_id` | `az account set` と同じサブスクリプション ID |
| `location` | 利用可能な基盤リージョンの識別子。表示名ではなく `eastus2` のような形式。例示リージョンの利用可能性は保証しません |
| `name_prefix` | グローバルに一意になる 3〜40 文字の小文字・数字・ハイフン。先頭は英字、末尾は英数字 |
| `inference_principal_object_id` | 推論するユーザーの Entra object ID。上記 `az ad signed-in-user show` の結果 |

グループやサービスプリンシパルに付与する場合も object ID を使ってください。サービスプリンシパルの application/client ID とは異なります。Terraform の実行主体と推論主体が別の場合、後者の object ID を指定します。

`deploy_model = false`、モデル関連の 3 項目は `null` のままにします。秘密情報は不要です。実値の tfvars、state、保存した plan、仮想環境は `.gitignore` の対象です。lock file は共有対象です。

Terraform はリソースプロバイダーを自動登録しません。未登録なら権限のある管理者が、利用サブスクリプションで次を実行してください。

```bash
az provider register --namespace Microsoft.CognitiveServices --wait
```

## 2. 基盤だけを作成する

ここからの `apply` は Azure リソースを作成・変更します。plan を確認してから実行してください。

```bash
terraform -chdir=infra init
terraform -chdir=infra plan -out=foundation.tfplan
terraform -chdir=infra apply foundation.tfplan
terraform -chdir=infra output
```

`deployment_enabled` が `false` で、plan に `azapi_resource.qwen` の作成がないことを確認します。この段階では GPU は作成されませんが、基盤や関連サービスの料金が常に無料とは限りません。

アカウント、プロジェクト、2 件の Foundry User 割り当てを作成します。プロジェクトのマネージド ID にも必要なアカウントスコープの権限を割り当てます。Foundry User は旧 Azure AI User と同じロール ID を使用しており、表示名の変更には依存しません。

## 3. 小型 Qwen とテンプレートを確認する

小型のテキスト生成用モデルとして [`Qwen/Qwen3-0.6B`](https://huggingface.co/Qwen/Qwen3-0.6B) を使用します。実際の `azure-huggingface` レジストリで Managed compute 対応と Apache 2.0 ライセンスを確認しています。当初候補の Qwen3-8B は同レジストリで確認できなかったため、より小さい対応モデルを選びました。ただし、別のプロジェクト・リージョン・クォータでの利用可能性は個別に確認してください。

1. [新 Foundry ポータル](https://ai.azure.com/nextgen) で、作成したアカウントとプロジェクトを選択します。
2. モデルカタログで **Hugging Face**、**Managed compute**、**Available in my Project** に絞り込み、Qwen を検索します。
3. モデルカードとデプロイ設定画面から、モデル URI、対応テンプレート URI、アクセラレーター種別を確認します。**ここではポータルから Deploy を実行しません。**
4. モデル版とテンプレートの互換性、Chat Completions 対応、コンテキスト上限、GPU 数、ライセンスを確認します。可能なら単一 GPU のテンプレートを選びます。
5. ポータルの **Managed compute** クォータ画面で利用枠を確認します。不足する場合は該当アクセラレーター・リージョンのクォータを申請します。承認と実容量の確保は別です。
6. [料金](https://azure.microsoft.com/pricing/details/ai-foundry-models/microsoft/) を確認してから、tfvars のモデル関連値を設定します。

必要な URI の形式は次のとおりです。`<...>` は実際に確認した値へ置き換えるための説明用表記です。

```text
model_id:
  azureml://registries/azure-huggingface/models/<モデルのアセット名>/versions/<数値バージョン>

deployment_template_id:
  azureml://registries/azure-huggingface/deploymenttemplates/<対応テンプレート名>/labels/latest
```

**モデルは固定バージョン、テンプレートは `/labels/latest` を指定します。** 実 API はテンプレートの `/versions/...` を `InvalidResourceProperties` で拒否します。モデルカードのコピー結果をバージョン形式へ変換しないでください。デプロイ前に解決先テンプレートの版・GPU 数を確認し、記録してください。`NoAutoUpgrade` を指定していますが、ラベルの参照先が変わる可能性があるため、新規作成・再作成時まで完全に同一のテンプレートを保証するものではありません。

今回レジストリで確認した組み合わせは次のとおりです。モデル v6、モデルが既定として参照するテンプレート v7、vLLM、A100 80 GB 1 基、40,960 トークンの構成です。

```hcl
model_id               = "azureml://registries/azure-huggingface/models/qwen--qwen3-0.6b/versions/6"
deployment_template_id = "azureml://registries/azure-huggingface/deploymenttemplates/qwen--qwen3-0-6b--40k-nvidia-a100/labels/latest"
accelerator_type       = "A100_80GB"
model_instance_count   = 1
```

CLI で参照元を確認する場合は、任意で `ml` 拡張を使用できます。これはレジストリの読み取り専用照会であり、Azure ML ワークスペースやオンラインエンドポイントは作成しません。

```bash
az extension add --name ml
az ml model show \
  --registry-name azure-huggingface --name qwen--qwen3-0.6b --label latest \
  --query "{model:id,defaultTemplate:default_deployment_template.asset_id,allowedTemplates:allowed_deployment_templates}"
az ml deployment-template show \
  --registry-name azure-huggingface \
  --name qwen--qwen3-0-6b--40k-nvidia-a100 --version 7 \
  --query "{name:name,version:version,accelerators:acceleratorMaps,environment:environmentId,scoringPath:scoringPath}"
```

`accelerator_type` はテンプレートに対応する `A100_80GB`、`H100_80GB`、`MI300_192GB` のいずれかです。VM SKU 名は指定しません。初期値の `model_instance_count = 1` は「モデル 1 インスタンス」であり、常に GPU 1 基とは限りません。

小型 Qwen が利用できない場合は、クォータ、モデル対応、利用リージョンを再確認してください。本サンプルは Qwen3-32B、classic、別のホスト方式へ自動で切り替えません。サンプル設定は安全のためモデル値を `null` のままにし、上記の確認済み URI も利用環境で再確認してから設定します。

## 4. GPU デプロイを有効化する

検証済みの `model_id`、`deployment_template_id`、`accelerator_type` を入力したら、`infra/terraform.tfvars` を `deploy_model = true` に変更します。

```bash
terraform -chdir=infra plan -out=model.tfplan
terraform -chdir=infra apply model.tfplan
terraform -chdir=infra output deployment_enabled
```

plan には `azapi_resource.qwen[0]` が 1 件追加され、SKU が `GlobalManagedCompute`、capacity が意図したモデルインスタンス数になる必要があります。未設定値や不正な形式は Terraform の入力検証で拒否します。**URI の実在・モデルとの互換性・クォータ・料金は、形式検証では確認できません。**

作成後に ARM から状態を確認します。

```bash
DEPLOYMENT_ID="$(terraform -chdir=infra output -raw managed_compute_deployment_id)"
az rest --method get \
  --url "https://management.azure.com${DEPLOYMENT_ID}?api-version=2026-05-15-preview" \
  --query "{state:properties.provisioningState,accelerator:properties.acceleratorType,instances:sku.capacity}" \
  --output json
```

`state` が `Succeeded` で、アクセラレーターとインスタンス数が指定どおりであることを確認します。

モデルは固定バージョンを使い、テンプレートは API が要求する `labels/latest`、アップグレード方針は `NoAutoUpgrade` としています。テンプレートの解決先やサービス側のセキュリティパッチまで完全に固定する設定ではありません。モデルまたはアクセラレーターを変更すると、API の不変属性に合わせて Terraform がデプロイを置換するため、停止が発生します。基盤リージョンや命名の変更もリソース再作成につながるので plan を確認してください。

## 5. Python から推論する

`deployment_enabled` が `true`、デプロイ状態が `Succeeded` であることを確認してから実行します。

```bash
source .venv/bin/activate
export FOUNDRY_OPENAI_BASE_URL="$(terraform -chdir=infra output -raw openai_base_url)"
export FOUNDRY_DEPLOYMENT_NAME="$(terraform -chdir=infra output -raw deployment_name)"

python scripts/chat.py \
  --prompt "Azure のマネージドサービスを使う利点を日本語で3つ説明してください。" \
  --max-tokens 512
```

アカウントの OpenAI 互換 base URL は `https://<account>.services.ai.azure.com/openai/v1/` です。`foundry_project_endpoint` の `/api/projects/...` を付けた URL は、この CLI には使用しません。要求の `model` には `Qwen/Qwen3-0.6B` やアセット URI ではなく **Terraform のデプロイ名** を渡します。

認証は `DefaultAzureCredential` と更新可能な bearer token provider を使用します。アカウントレベルの OpenAI 互換ルート用スコープは `https://cognitiveservices.azure.com/.default` です。ローカルでは `az login` の主体に加え、環境変数などで別の資格情報を設定していないかも確認してください。サンプルで固定した Azure Identity では、`export AZURE_TOKEN_CREDENTIALS=AzureCliCredential` を指定するとローカルの Azure CLI 認証に限定できます。`.env` ファイルは自動読み込みしません。

Qwen3 の文書化された soft switch `/no_think` を system メッセージで送信します。統合された `/openai/v1/` 経路は vLLM 固有の `chat_template_kwargs` を HTTP 400 で拒否するため、標準 Chat Completions パラメーターだけを使用します。モデル側で推奨されている non-thinking 設定として temperature 0.7、top-p 0.8 を使用しています。Qwen が回答の前に出力する空の `<think>...</think>` ブロックだけを除去します。空ブロックしかない場合や、空でない reasoning ブロックが返った場合は成功扱いにしません。

成功時は回答本文だけを標準出力へ表示します。設定不備は終了コード 2、認証・HTTP・通信エラー、空回答、トークン上限での打ち切りは終了コード 1 です。エラーは標準エラーへ出し、トークンや API 応答のエラー本文は表示しません。SDK の通信タイムアウトは 60 秒、再試行は SDK 既定の動作です。

## 6. GPU を削除し、課金を止める

**リクエストがなくても GPU の稼働中は課金されます。自動停止や scale-to-zero は実装していません。**

基盤を残す場合は、`infra/terraform.tfvars` の `deploy_model` を **false に戻して保存** してから実行します。コマンドラインで一度だけ上書きすると、次の apply で再作成される恐れがあるため、設定ファイル自体を戻してください。

```bash
terraform -chdir=infra plan -out=disable-model.tfplan
terraform -chdir=infra apply disable-model.tfplan
terraform -chdir=infra output deployment_enabled
unset FOUNDRY_OPENAI_BASE_URL FOUNDRY_DEPLOYMENT_NAME
```

plan がモデルデプロイの削除になっていること、apply が成功して Foundry 上から対象デプロイが消えたことを確認します。削除後の `deployment_name` と `managed_compute_deployment_id` は Terraform outputs から省略されます。

専用のサンプル環境全体を削除する場合は、対象サブスクリプションと state を確認してから実行します。

```bash
terraform -chdir=infra plan -destroy -out=destroy.tfplan
terraform -chdir=infra apply destroy.tfplan
```

アカウントの soft delete を永久削除する purge は無効にしています。削除後すぐに同じ名前を再利用できない場合は、別の一意な `name_prefix` を使用するか、管理者に復旧・保持状態を確認してください。モデル削除による GPU 解放と、アカウントの soft delete / purge は別の操作です。

state ファイルを消す、Terraform から追跡を外す、CLI を終了するだけでは Azure リソースや課金は止まりません。

## ローカル検証

サブスクリプション、Azure ログイン、GPU、実値の tfvars は不要です。プロバイダーと Python パッケージの取得にはインターネット接続が必要です。

```bash
terraform -chdir=infra init -backend=false
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
terraform -chdir=infra test

.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python -m pip check
```

Terraform テストは両プロバイダーをモックし、GPU 無効・有効・再無効化、capacity、認証設定、入力不備を確認します。実際の tfvars が存在しても、テスト用入力と既定値で上書きして分離します。テスト内の `apply` もモックに対する操作で、実 Azure には接続しません。アセット URI はテスト専用の架空値です。Python テストは SDK の HTTP transport もモックし、リクエスト形式、bearer 認証、正常回答と失敗時の終了を確認します。

実環境の受け入れでは、別途、クォータとアセット互換性、`Succeeded`、日本語の回答、再 plan の差分、無効化・destroy 後の削除を確認してください。ローカル検証の成功はこれらの代わりにはなりません。

## トラブルシューティング

| 症状 | 確認すること |
| --- | --- |
| Terraform が GPU 作成前に入力エラー | 必須値、UUID、モデルの `/versions/<数値>`、テンプレートの `/labels/latest`、アクセラレーター名。サンプルの `REPLACE_WITH_...` は実値へ変更 |
| `DeploymentTemplate must use the '/labels/latest' format` | テンプレートのバージョン参照は実 API で非対応。モデルは固定版のまま、対応するテンプレートのラベル URI を使用 |
| Azure のモデル作成が失敗 | アセットの実在、モデル・テンプレートの互換性、Managed compute の専用クォータ、実容量、作成主体の権限 |
| カタログに小型 Qwen が表示されない | 対象プロジェクト、利用可能リージョン、専用クォータ。公開カードだけでは利用可否は確定しない |
| Entra ID 認証失敗 / HTTP 401 | `az login`、tenant、DefaultAzureCredential が使用する主体 |
| HTTP 403 | 推論主体の object ID、アカウントスコープの Foundry User、RBAC の反映、組織のネットワークポリシー |
| HTTP 404 | アカウントの base URL、デプロイ名、`Succeeded`、テンプレートの Chat Completions 対応 |
| HTTP 400 | 対応パラメーター、トークン・コンテキスト上限。統合経路では `chat_template_kwargs` などの runtime 固有フィールドを追加しない |
| 空回答 / トークン上限 | `--max-tokens`、Qwen の thinking 設定とテンプレート。reasoning のみを成功扱いにはしない |
| HTTP 429 / 接続失敗 | スロットリング、稼働状況、DNS、パブリックアクセスと組織ポリシー |
| role assignment が既に存在する | 管理対象を確認して既存割り当てを import するなど、管理者と調整する。既存環境への取り込みはこのサンプルの対象外 |

## 費用とプレビューの制約

- 料金の概念は **テンプレートの GPU 数 × モデルインスタンス数 × 稼働時間 × 単価** です。小型モデルでも安価な GPU を自由に選べるとは限りません。
- 実機確認時の East US 2 / Global A100 80 GB の公開従量単価は **1 基あたり 3.95 USD/時** でした。これは参考値であり、実際の契約料金・為替・税などは別途確認してください。
- 現在のスコープは Global です。基盤に日本のリージョンを指定しても、日本国内での推論処理を保証しません。
- プレビューには SLA がなく、本番向けの保証はありません。モデルや API、リージョン、料金は変わる可能性があります。
- 組み込みの Content Safety フィルターは Managed compute の推論経路に含まれません。このサンプルではフィルタリングを追加していません。安全性評価とモデルのライセンス確認は別途必要です。
- Terraform state はローカルに保存します。キーを保存しない構成でも state 自体は安全に保管してください。共有・本番用途ではアクセス制御されたリモート backend、閉域化、監視、費用管理を別途設計してください。

## 参考

- [Managed compute 概要](https://learn.microsoft.com/azure/foundry/concepts/managed-compute-overview)
- [Managed compute のデプロイと推論](https://learn.microsoft.com/azure/foundry/how-to/deploy-models-managed)
- [Hugging Face モデルの利用可否](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/hugging-face-models)
- [Managed compute の ARM / Terraform AzAPI スキーマ](https://learn.microsoft.com/azure/templates/microsoft.cognitiveservices/2026-05-15-preview/accounts/managedcomputedeployments)
- [Foundry の RBAC](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)
- [Qwen3-0.6B と non-thinking の設定](https://huggingface.co/Qwen/Qwen3-0.6B)
