---
name: check-experiment
description: Quick health check of experiment configuration before launching
user_invocable: true
model: haiku
---

Perform a pre-launch experiment check:

1. Read and validate manifest.yaml:
   - Verify entrypoint exists and is executable
   - Check resource allocations are reasonable
   - Validate environment variables

2. Check git status:
   - Show uncommitted changes
   - Verify we're on the right branch
   - Show last few commits

3. Review recent experiment logs (if available)

4. Summarize:
   - What will run when launched
   - Any potential issues
   - Recommended next steps

Keep the output concise and actionable.
