Session wrap-up checklist. Execute ALL steps in order:

1. **Update docs** — For any work done this session: update the changelog / README / relevant docs. Add or close `[x]` task entries and keep the format consistent with existing entries.

2. **Check for sensitive data** — Scan all staged/unstaged changes and recent commits before pushing. Use `git diff` (staged + unstaged) and `git log -p` on recent commits. Flag and STOP if any of these appear — do NOT push until clean:
   - **Usernames / emails** — real account names, personal emails, service-account names.
   - **Passwords** — literal passwords, `password=`, `PASS=`, basic-auth in URLs (`https://user:pass@host`).
   - **Secrets / keys / tokens** — API keys, access tokens, private keys (`BEGIN ... PRIVATE KEY`), `.env` values, bearer tokens, cloud credentials.

   Quick scan:
   ```bash
   git diff HEAD | grep -niE 'password|passwd|secret|token|api[_-]?key|bearer|private key|BEGIN .*PRIVATE|aws_|://[^/]+:[^@/]+@'
   ```
   Review every hit. If anything real is found, replace with a placeholder, move it to a gitignored/`.env` file, and add an `.example` template.

3. **Commit** — Stage and commit any remaining uncommitted changes with a clear, descriptive message.

4. **Push** — `git push` to your remote (only after the sensitive-data check passes).

5. **Summary** — Print a short session summary: what was done, what was committed, and what's left (if anything).
