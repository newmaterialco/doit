# Reliable Memory Smoke Test

Run this after applying the Supabase migration and deploying the runner/iOS app.

## App Test

1. In Doit, ask: `Change my sign off to Gabe`.
2. Wait for the task to finish.
3. Open Passbook and confirm a `What I know about you` card appears for the signoff.
4. Open Settings > Memory and confirm the memory appears under `About you`.
5. Ask a second task that requires an email signoff, without mentioning Gabe.
6. Confirm Doit uses `Gabe`.

## VM Checks

On the VM/VPS that runs Hermes, verify the projected Hermes file:

```bash
sudo sed -n '1,160p' /root/.hermes/profiles/<profile>/memories/USER.md
```

Expected: the active signoff memory appears in `USER.md`.

Then delete or forget the memory in the app, run another task, and verify the
file no longer contains that entry.

## Supabase Checks

Check the `memories` row:

- `source` is `doit` for extracted memories or `user` for pinned memories.
- `memory_status` is `proposed` before approval or `active` after approval.
- `sync_status` becomes `synced` after a runner pass.
- `last_sync_at` is populated for active memories that reached Hermes.

Check `memory_settings`:

- Turning off automatic memory suggestions sets `automatic_suggestions_enabled=false`.
- Custom instructions are saved in `custom_instructions`.

