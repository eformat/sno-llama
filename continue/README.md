# Continue - Deploy your own IDE Python Coding Assistant

Code assistant based on [the instructions here.](https://ai-on-openshift.io/demos/codellama-continue/codellama-continue)

Uses the opensource code plugin [Continue](https://docs.continue.dev). Download the [VSIX](https://openvsxorg.blob.core.windows.net/resources/Continue/continue/linux-x64/0.9.124/Continue.continue-0.9.124@linux-x64.vsix) plugin file for your IDE (vscode or jetbrains).

Serve up your [coding assistant model](../serving/serving-code-llama.yaml) using RHOAI.

```bash
oc apply serving/serving-code-llama.yaml
```

Configure your IDE - vscode in this [config.json](config.json) example.
