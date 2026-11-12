import * as path from "path";
import * as vscode from "vscode";
import { ExtensionContext } from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions, TransportKind } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: ExtensionContext): void {
    require("fs").writeFileSync("/tmp/soleil_ext_active.txt",
        "activated at " + new Date().toISOString());   // ground-truth marker

    const serverModule = context.asAbsolutePath(path.join("server", "lsp", "server.lua"));

    const serverOptions: ServerOptions = {
        command: "lua5.1",
        args: [serverModule],
        options: { cwd: path.dirname(serverModule) }
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ language: "soleil" }]
    };

    client = new LanguageClient("soleilLSP", "Soleil Language Server", serverOptions, clientOptions);
    // client.start() returns a promise — wrap it as a disposable
    const started = client.start();
    context.subscriptions.push({ dispose: () => started.then(() => client?.stop()) });

    // ---- auto-`end`: Enter after a block opener inserts the closer below
    context.subscriptions.push(vscode.workspace.onDidChangeTextDocument((event) => {
        const editor = vscode.window.activeTextEditor;
        if (!editor || event.document !== editor.document) return;
        if (event.document.languageId !== "soleil") return;
        if (editor.selections.length > 1) return;
        const change = event.contentChanges[0];
        if (!change || change.text !== "\n") return;          // only Enter

        const openerLine = event.document.lineAt(change.range.start.line).text;
        const opener = openerLine.match(/^(\s*)(class|function|if|while|for|repeat|do)\b/);
        if (!opener) return;
        if (/\bend\s*$/.test(openerLine)) return;              // one-liner already closed

        const cursorLine = editor.selection.active.line;
        const baseIndent = (event.document.lineAt(cursorLine).text.match(/^\s*/) || [""])[0];
        editor.edit((builder) => {
            builder.insert(new vscode.Position(cursorLine + 1, 0), baseIndent + "end\n");
        });
        const blockIndent = baseIndent + "    ";
        editor.selection = new vscode.Selection(
            new vscode.Position(cursorLine, blockIndent.length),
            new vscode.Position(cursorLine, blockIndent.length));
    }));
}

export function deactivate(): Thenable<void> | undefined {
    return client?.stop();
}
vscode.languages.onDidChangeDiagnostics((e) => {
    for (const uri of e.uris) {
        const diags = vscode.languages.getDiagnostics(uri);
        console.log("DIAG STORE:", uri.toString(), "→", diags.length, "entries");
        for (const d of diags.slice(0, 3)) console.log("   ", d.severity, d.message.slice(0, 60));
    }
});