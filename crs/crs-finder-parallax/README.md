# crs-finder-parallax

Claude Code bug-finding CRS integrated into `CRC-Template`. It reads the target
source, runs the supported analysis helpers, and submits verified crashing inputs
(PoVs) through OSS-CRS.

This directory originated from Team Atlanta's
`crs-bug-finding-template`; the upstream revision and local migration delta are
recorded in the repository-root provenance document. The supported production
entrypoint is `run_crs`, for C/C++ address-sanitized libFuzzer targets. Upstream
tutorial and probe entrypoints require `CRS_ENABLE_EXPERIMENTAL_ENTRYPOINTS=1`.

## Layout

- **`builder/`**: build-phase scripts, each producing one build variant of the
  target via OSS-Fuzz `compile`.
- **`oss-crs/`**: the oss-crs integration manifest (`crs.yaml`, `dockerfiles/`,
  example compose).
- **`tutorial/`**: the 5-chapter hands-on tutorial for building this template
  into an effective CRS.
- **`crs/`**: the CRS implementation. `CLAUDE.md.j2` is the agent's
  standing-instructions template. Its subdirectories:
  - **`crs/entrypoint/`**: the run-phase entrypoints plus the `entrypoint.sh`
    multiplexer. `run_crs` is the production path; other upstream entrypoints
    are retained for explicitly opted-in experimentation.
  - **`crs/src/`**: runtime and prompt plumbing (`runtime.py`, `prompts.py`,
    `claude_node.py`).
  - **`crs/tools/`**: the production `crs-fuzz`, `crs-codeql`, and
    `crs-coverage` helpers. The upstream AFL helper remains uninstalled.
  - **`crs/skills/`**: Claude Code skill docs.
  - **`crs/roles/`**: entrypoint role/system prompts.
  - **`crs/agents/`**: Task-tool subagent definitions.
