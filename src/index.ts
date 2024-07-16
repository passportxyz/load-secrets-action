import path from "path";
import url from "url";
import * as core from "@actions/core";
import * as exec from "@actions/exec";
import { validateCli, item } from "@1password/op-js";
import { validateAuth } from "./utils";

const loadAllSecretsAction = async () => {
	try {
		// Validate that a proper authentication configuration is set for the CLI
		validateAuth();

		// Download and install the CLI
		await installCLI();

		const secrets: Record<string, string> = {};

		const itemsList = item.list({ vault: "Test" });
		itemsList.forEach(({ title }) => {
			const thisItem = item.get(title, { vault: "Test" });
			thisItem.fields?.forEach(({ id, value }) => {
				if (!value) return;

				// Masks this value in all subsequent logs
				core.setSecret(value);
				secrets[id] = value;
			});
		});

		console.log("All secrets:");
		console.log(JSON.stringify(secrets, null, 2));

		core.setOutput("secrets", JSON.stringify(secrets));
	} catch (error) {
		// It's possible for the Error constructor to be modified to be anything
		// in JavaScript, so the following code accounts for this possibility.
		// https://kentcdodds.com/blog/get-a-catch-block-error-message-with-typescript
		let message = "Unknown Error";
		if (error instanceof Error) {
			message = error.message;
		} else {
			String(error);
		}
		core.setFailed(message);
	}
};

// This function's name is an exception from the naming convention
// since we refer to the 1Password CLI here.
// eslint-disable-next-line @typescript-eslint/naming-convention
const installCLI = async (): Promise<void> => {
	// validateCli checks if there's an existing 1Password CLI installed on the runner.
	// If there's no CLI installed, then validateCli will throw an error, which we will use
	// as an indicator that we need to execute the installation script.
	await validateCli().catch(async () => {
		const currentFile = url.fileURLToPath(import.meta.url);
		const currentDir = path.dirname(currentFile);
		const parentDir = path.resolve(currentDir, "..");

		// Execute bash script
		const cmdOut = await exec.getExecOutput(
			`sh -c "` + parentDir + `/install_cli.sh"`,
		);

		// Add path to 1Password CLI to $PATH
		const outArr = cmdOut.stdout.split("\n");
		if (outArr[0] && process.env.PATH) {
			const cliPath = outArr[0]?.replace(/^(::debug::OP_INSTALL_DIR: )/, "");
			core.addPath(cliPath);
		}
	});
};

void loadAllSecretsAction();
