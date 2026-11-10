/** The engine kit as the running service makes it: on its own folder, with the real check. */

import { EngineKit, engineRoot } from "./kit.js";
import { engineSelfCheck } from "./selfCheck.js";
import { EngineStore } from "./store.js";

/** The engine looks after itself as browsers start (kit.ts `ensure`) unless `AGENTSWITCH_ENGINE_AUTO=0`. */
export function newEngineKit(home: string, env: NodeJS.ProcessEnv = process.env): EngineKit {
  const root = engineRoot(home);
  return new EngineKit({ root, selfCheck: engineSelfCheck(new EngineStore(root)), auto: env.AGENTSWITCH_ENGINE_AUTO !== "0" });
}
