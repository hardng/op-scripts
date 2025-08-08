
# op-scripts

一个集中管理的运维脚本，通过一个入口脚本 `main.sh` 即可执行任意脚本，无需 clone 仓库。

## 快速开始

### 列出可用脚本

```
curl -sL https://raw.githubusercontent.com/hardng/op-scripts/main/main.sh | bash -s -- -l
```

### 执行脚本

```
curl -sL https://raw.githubusercontent.com/hardng/op-scripts/main/main.sh | bash -s -- <script_name> [args...]
```

示例

```
curl -sL https://raw.githubusercontent.com/hardng/op-scripts/main/main.sh | bash -s -- deploy prod v1.2.3
```