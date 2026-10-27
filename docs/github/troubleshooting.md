# 🛠️ Troubleshooting & Break-and-Fix Log (GitHub & CI/CD)

This document records every issue, error, and configuration fix encountered during **Day 2: Git, GitHub, and CI/CD Pipelines** in **chronological order**—showing the symptom, root cause, and exact fix so future debugging is fast and structured.

---

## Issue #01 — `actions/setup-node@v4` Fails with `Dependencies lock file is not found` (`cache-dependencies` vs `cache-dependency-path`)
* **Stage:** `.github/workflows/ci.yml` (`frontend` job — Step 2 `Setup Node.js 22`)
* **Symptoms:**
  1. Red Error in GitHub Actions log:
     ```text
     Error: Dependencies lock file is not found in /home/runner/work/opsticket-practice/opsticket-practice. Supported file patterns: package-lock.json,npm-shrinkwrap.json,yarn.lock
     ```
  2. Yellow Warning directly above the error:
     ```text
     Warning: Unexpected input(s) 'cache-dependencies', valid inputs are ['always-auth', 'node-version', 'node-version-file', 'architecture', 'check-latest', 'registry-url', 'scope', 'token', 'cache', 'cache-dependency-path', 'mirror', 'mirror-token']
     ```
* **Root Cause:**
  1. **Why `working-directory: ./frontend` didn't help:** Setting `defaults.run.working-directory: ./frontend` only changes the directory for terminal commands (`run:`). Pre-built GitHub Actions plugins (`uses:`, such as `actions/setup-node@v4`) always execute from the repository root folder (`/home/runner/work/...`).
  2. **Why our lockfile path was ignored:** We wrote `cache-dependencies: frontend/package-lock.json`, which is not a valid input name for `actions/setup-node@v4`. The action printed a yellow warning, ignored the line, and fell back to searching the repository root for `package-lock.json`—where none exists in a monorepo (`frontend/` + `backend/`).
* **Fix:**
  Updated line 33 of `.github/workflows/ci.yml` to use the exact input name listed in the warning (`cache-dependency-path`):
  ```yaml
  - name: Setup Node.js 22
    uses: actions/setup-node@v4
    with:
      node-version: 22
      cache: "npm"
      cache-dependency-path: frontend/package-lock.json
  ```

---

## Issue #02 — Pull Request Allows Merging Even When CI Action Fails (Red ❌)
* **Stage:** GitHub Repository Settings → Branch Protection Rules (`main`)
* **Symptom:**
  On Pull Request #1, even though the `frontend` CI job failed with a red ❌, the green **"Merge pull request"** button on GitHub remained clickable and allowed merging broken code into `main` (which immediately triggered a second failing `push` run on `main`).
* **Root Cause:**
  Enabling **"Require a pull request before merging"** only forces changes to go through a PR—it does not tell GitHub *which* automated CI jobs must pass before the Merge button unlocks. Additionally, GitHub cannot list a job name (like `frontend`) in Branch Protection search until that workflow job has run at least once on the repository.
* **Fix:**
  After the first workflow run registered the `frontend` job name with GitHub, updated **Settings → Branches → Branch protection rule for `main`**:
  1. Checked **☑ Require status checks to pass before merging** and added `frontend` to the required checks list.
  2. Checked **☑ Require branches to be up to date before merging** so PRs must be tested against the latest `main` code before merging.

---

## Issue #03 — Frontend Unit Test (`src/api.test.js`) Fails in CI (`Failed to parse URL from /api/tickets/stats`)
* **Stage:** `.github/workflows/ci.yml` (`frontend` job — `Run unit tests` / `npm test`)
* **Symptoms:**
  1. GitHub Branch Protection successfully **blocked** the Merge button when `npm test` failed.
  2. `vitest` reported 1 failing test in `frontend/src/api.test.js:20:5`:
     ```text
     FAIL  src/api.test.js > API Client > handles network errors gracefully
     AssertionError: expected [Function] to throw error including 'Unable to connect to the API server' but got 'Failed to parse URL from /api/tickets…'
     - Expected: Unable to connect to the API server
     + Received: Failed to parse URL from /api/tickets/stats
     ```
* **Root Cause:**
  1. In `frontend/src/api.js`, the `try / catch` block that translates `TypeError` network errors into `'Unable to connect to the API server. Please check your network connection.'` was placed inside `handleResponse(response)` instead of wrapping the `await fetch(...)` call itself.
  2. When `await fetch('/api/tickets/stats')` threw a `TypeError` during the test (because no server or browser host exists in the Node.js test runner), `fetch()` crashed **before** `handleResponse()` was ever called.
* **Fix:**
  Added a `request(url, options)` wrapper in `frontend/src/api.js` that wraps `await fetch(url, options)` inside the `try / catch (err)` block so any `TypeError` thrown by `fetch` is caught and converted into the expected user-friendly error message.

