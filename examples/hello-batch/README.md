# Example: hello-batch

A minimal two-task batch you can run end-to-end to verify the workflow.

```bash
# from repo root
scripts/gc-parallel.sh examples/hello-batch --max-parallel 2
```

After it finishes:

- `examples/hello-batch/output/readme-from-worker.md` — written by worker `readme`
- `examples/hello-batch/output/license-blurb.md`     — written by worker `license-blurb`
- `examples/hello-batch/*.summary`                   — read these (short)
- `examples/hello-batch/*.log`                       — full worker logs (do NOT read by default)

The two workers touch disjoint output paths, so they're safe to run in parallel.
