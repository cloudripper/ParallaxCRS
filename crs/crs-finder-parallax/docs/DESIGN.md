# crs-finder-parallax: design

Status: plan. Nothing here is built yet unless marked **(done)**.

The finder runs inside OSS-CRS. cc-fuzzer supplies the deterministic judgement
on either side of the fuzzer (triage, minimization, patch validation) through
its CRS adapter, `cc_fuzzer_core.crs`. ParallaxCRS owns the scheduler, the
fuzzers, the agents and the exchange with the patcher.

## 1. Getting cc-fuzzer into the container

Decision: **vendored, pinned wheel.**

1. `scripts/vendor-cc-fuzzer.sh` builds the `cc_fuzzer_core` wheel from a
   pinned cc-fuzzer commit into `crs/crs-finder-parallax/vendor/`, and writes
   `vendor/cc-fuzzer.lock.json` (commit, version, wheel sha256).
2. `oss-crs/dockerfiles/runner.Dockerfile` installs it before the finder:

   ```dockerfile
   COPY vendor/ /opt/vendor/
   RUN pip3 install --no-index --find-links /opt/vendor cc-fuzzer-core==<pinned>
   ```

3. `pyproject.toml` lists `cc-fuzzer-core==<pinned>`, so a missing wheel fails
   the image build, not the run.
4. Image smoke check: `cc-fuzzer crs triage --help` (also proves the core runs
   on the runner's Python, >=3.10).

The core is stdlib-only, so the wheel brings no transitive dependencies.

## 2. Crash flow

Decision: **triage everything.** Nothing reaches `/artifacts/povs` without
passing triage.

1. libFuzzer `-artifact_prefix` moves from `/artifacts/povs/` to
   `/work/crashes/`. Agents write candidates to `/work/candidates/`.
2. A deterministic triage watcher thread in `run_crs.py` (next to
   `register_submit_dirs`) takes each new file in those two dirs through:
   1. `crs.triage`: replay, stack-hash-preserving minimization, byte
      sensitivity map, final verification with `libCRS run-pov` as a
      `command:` oracle;
   2. dedup by stack hash (and by root-cause cluster, §4.4);
   3. promotion of the **minimized** PoV to `/artifacts/povs`, plus its
      evidence record (§3), which the existing submit watchers pick up.
3. A PreToolUse hook denies agent writes to `/artifacts/povs`.
4. `flush_submissions` still runs in `finally`; the watcher drains its queue
   first.

## 3. Handoff to the patcher

Today: the finder submits raw PoV bytes only. The patcher fetches
`POV/BUG_CANDIDATE/DIFF/SEED` once at startup
(`crs-patcher-parallax/patcher.py`), makes one attempt, and submits the first
`.diff` (submission is final). `scripts/run-e2e.sh` stages only PoVs.

### 3.1 What crosses over

For every promoted PoV, two artifacts:

| Exchange type | Content |
|---|---|
| `POV` | the minimized input |
| `BUG_CANDIDATE` | `parallax-evidence/v1` JSON, keyed by the PoV's sha256 |

`parallax-evidence/v1`:

```json
{
  "schema": "parallax-evidence/v1",
  "pov_sha256": "...", "original_sha256": "...",
  "harness": "...", "stack_hash": "...", "category": "heap-buffer-overflow",
  "top_frame": "...", "frames": ["..."], "sanitizer_excerpt": "...",
  "sizes": {"original": 4096, "minimized": 12},
  "sensitivity": { "...input-sensitivity/v1 from cc-fuzzer..." },
  "site": {"capacity": "...", "extent": "...", "offset": "...",
           "guards": ["..."], "operand": "..."},
  "root_cause": {"write_site": "...", "method": "watchpoint|rr|none"},
  "cluster": "...", "verdict": {"step": "command:run-pov", "status": "confirmed"},
  "cc_fuzzer": {"version": "...", "commit": "..."}
}
```

### 3.2 Patcher side

1. Join each PoV to its record by sha256.
2. Group by `cluster` (falls back to `stack_hash`) and build **one prompt per
   cluster**. The current "your patch must fix all POV variants" instruction is
   impossible to satisfy when two unrelated bugs are in the fetched set.
3. Enforce cc-fuzzer's patch gates, mapped to libCRS, before any write to
   `/patches` is allowed:

   | cc-fuzzer gate | libCRS |
   |---|---|
   | `before` | `run-pov` on base build must crash (else stale) |
   | `apply` + `build` | `apply-patch-build` returns a rebuild id |
   | `after` | `run-pov --rebuild-id` for every PoV in the cluster |
   | `tests` | `apply-patch-test` |

### 3.3 Open questions

1. Can a finder register a `BUG_CANDIDATE` submit dir in libCRS? The oss-crs
   submodule is not checked out, so unverified. Fallback: write records into
   the e2e staging (`pov-manifest.json`) and pass `--bug-candidate-dir`.
2. The patcher only sees what the exchange holds at its boot. In e2e this is
   fine (sequential). In a live ensemble the finder should submit its first
   strong find early.

## 4. Finding the kernel of a crash input

"Crash" is not "crash with the same cause", and the shortest input is not
necessarily the essential one. Four layers, cheapest first.

### 4.1 Byte minimum (done, cc-fuzzer `minimize.minimize`)

ddmin where every candidate must reproduce with the **same stack hash**, not
merely crash. Prevents sliding onto a different bug.

### 4.2 Byte sensitivity map (done, cc-fuzzer `minimize.sensitivity`)

Mutate each byte of the minimized PoV (`b ^ 0xFF`, `b ^ 0x01`) and classify:

| Mark | Class | Meaning |
|---|---|---|
| `#` | load-bearing | every mutation loses the bug |
| `~` | constrained | some mutations keep it (a range, not an exact value) |
| `.` | free | every mutation keeps the bug (framing, filler) |
| `?` | unknown | probe budget ran out |

Mutations that crash *elsewhere* are recorded as neighbouring bugs with the
offsets that reach them. Output: `input-sensitivity/v1` (mask, spans,
neighbours). This tells the patcher which input bytes decide the faulting
operand.

### 4.3 Crash site vs root cause (ParallaxCRS role + gdb skill)

The stack hash names where the program broke, not where state first went bad.
From the faulting address, a hardware watchpoint (gdb skill) or `rr` reverse
execution finds the earlier write that corrupted it. That write site goes into
`root_cause` next to the static `site` join.

### 4.4 Collapsing variants onto one cause (cc-fuzzer `crs.check_patch`)

Two PoVs with different stack hashes can share a root cause. If one validated
patch (on a rebuild) fixes both, they join one cluster and the shortest PoV
becomes the representative.

## 5. Agents, skills, roles

Roles by artifact ownership:

| Role | Writes | Notes |
|---|---|---|
| pov-hunter (top-level; replaces pov-gen) | `/work/candidates` | keeps the "Before saving a POV" checklist, ends with submit-candidate |
| seed-gen | `/artifacts/corpus/<harness>` via `crs.safe_seeds` | uncovered bug candidates |
| pov-gen-cov | `/work/candidates` | covered bug candidates |
| query-analyst | notes only | CodeQL/coverage, read-only |

Skills: keep `gdb`, `run-pov`; add `submit-candidate`, `minimize`, `query`,
`seed-safety`.

ParallaxCRS keeps its own oss-crs-native roles and `CLAUDE.md.j2`. cc-fuzzer's
rendered prompts assume the `fuzz/` campaign layout and are not used here.

Topology (single top-level agent vs orchestrator plus subagents): open.

## 6. cc-fuzzer changes this depends on

1. Authoritative verifier evidence: a `run-pov` confirmation must grade
   `strong`, since every OSS-CRS binary is a libFuzzer build and local replay
   alone grades `weak`.
2. Configurable protected submission dir for the gate (hardcoded to
   `fuzz/findings/` today).
3. Python 3.10 check in CI.
4. `docs/EMBEDDING.md`: stop suggesting `prompts.render(..., "oss-fuzz")` for a
   CRS.
5. Byte sensitivity map (§4.2) **(done)**.

## 7. Repo hygiene (separate commit)

- `submission.yaml` points at nonexistent `crs/crs-*-claude-code`.
- Compose keys disagree with `crs.yaml` and `run-finder.sh` `CRS_NAME`.
- `setup.sh` checks four configs that do not exist.
- `required_llms` disagrees with `litellm-config.yaml`.
- `afl-builder.Dockerfile` unused; `example-compose.yaml` stale.
