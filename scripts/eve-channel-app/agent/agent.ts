import { defineAgent } from "eve";
import { mockModel } from "eve/evals";

export default defineAgent({
  model: mockModel(({ lastUserMessage }) => `reply from eve: ${lastUserMessage}`),
  modelContextWindowTokens: 4096,
});
