import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

export default defineAgent({
  model: mockModel(({ lastUserMessage, userMessageCount }) =>
    `reply ${userMessageCount}: ${lastUserMessage}`,
  ),
  modelContextWindowTokens: 4096,
});
