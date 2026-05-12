# Model Catalog Debugging Guide

## Issue Summary

Models in the catalog have non-functional HuggingFace URLs. When the app attempts to download MLX models, the HuggingFace API returns **HTTP 403 - "Host not in allowlist"**, which is a Cloudflare protection response.

```
curl https://huggingface.co/api/models/mlx-community/Llama-3.2-1B-Instruct-4bit
→ "Host not in allowlist"
```

## Root Causes

### 1. Cloudflare Protection on HuggingFace API
HuggingFace uses Cloudflare to protect its API endpoints from automated requests (scripts, CLI tools, bots). This blocks direct API calls from curl and other CLI utilities.

**Workaround in the app**: The app sends proper User-Agent headers mimicking a mobile browser:
```swift
request.setValue(
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    forHTTPHeaderField: "User-Agent"
)
```

This allows the app to bypass Cloudflare's initial checks, but **the actual HF API call still fails** if the repository doesn't exist.

### 2. Repository Names May Be Incorrect
The current model catalog URLs use the format:
```
https://huggingface.co/mlx-community/{model-name}
```

The `mlx-community` organization may not have repositories with these exact names, or these repositories may no longer be maintained.

**Current catalog models:**
- mlx-community/Llama-3.2-1B-Instruct-4bit
- mlx-community/Llama-3.2-3B-Instruct-4bit
- mlx-community/Phi-3.5-mini-instruct-4bit
- mlx-community/gemma-2-2b-it-4bit
- mlx-community/SmolLM2-360M-Instruct-4bit
- mlx-community/SmolLM2-1.7B-Instruct-4bit
- mlx-community/gemma-3-8b-it-4bit
- mlx-community/Mistral-7B-Instruct-v0.3-4bit
- mlx-community/Meta-Llama-3.1-8B-Instruct-4bit

## Verification Strategy

### Option A: Use Browser to Check Existence (Manual)
1. Visit `https://huggingface.co/mlx-community` in a browser
2. Search for each model name in the organization
3. Verify the exact repository name and structure
4. Note any case sensitivity differences

### Option B: Use HuggingFace CLI (if available)
```bash
# Install HF CLI
pip install huggingface-hub

# Try to access repo info
huggingface-cli repo-info mlx-community/Llama-3.2-1B-Instruct-4bit
```

### Option C: Use Alternative Endpoints (for reference)
Some models might be hosted under different organizations:
- `hf-internal-testing/` (test repos)
- Individual model authors (e.g., `meta-llama/`, `openai-community/`)
- Regional mirrors or cached versions

## Recommended Fixes

### Fix 1: Update Model URLs to Use mlx:// Scheme
The app supports the `mlx://` custom scheme for direct repo imports:

```swift
downloadURL: URL(static: "mlx://mlx-community/Llama-3.2-1B-Instruct-4bit")
```

This avoids the HTTP probe and directly passes the repo ID to `HuggingFaceAPIClient.fetchModelFiles()`.

**Advantage**: Cleaner, avoids the 403 issue earlier in the pipeline.
**Note**: The app will still need to access HF API to fetch the file manifest, so this doesn't completely solve the issue if the repos don't exist.

### Fix 2: Verify and Correct Repository Names
1. Use a browser to visit `https://huggingface.co/mlx-community`
2. Confirm each repository exists
3. Check for case-sensitivity issues (e.g., `gemma-2-2b-it-4bit` vs `Gemma-2-2B-IT-4bit`)
4. Update `ModelCatalogService.swift` with corrected URLs

### Fix 3: Use Alternative Model Sources
If `mlx-community` repos don't exist or are unavailable:

**Option 3A: Use MLX Framework Default Models**
```swift
// MLX recommends these models:
downloadURL: URL(static: "mlx://mlx-community/Llama-2-7b-chat-4bit"),
downloadURL: URL(static: "mlx://mistralai/Mistral-7B-Instruct-v0.1"),
```

**Option 3B: Use QuantFactory or TheBloke Conversions**
```swift
// QuantFactory provides GGUF conversions optimized for various backends
downloadURL: URL(static: "https://huggingface.co/QuantFactory/..."),
```

**Option 3C: Host Models on App's Own CDN**
Use a private CDN or S3 bucket to serve models directly, bypassing HuggingFace altogether.

## Network Configuration Checks

### 1. Check App Transport Security (ATS)
Create `Info.plist` with ATS exceptions if needed:
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>huggingface.co</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSTemporaryExceptionAllowsInsecureHTTPLoads</key>
            <false/>
        </dict>
    </dict>
</dict>
```

**Current status**: The app doesn't have an explicit `Info.plist` (Xcode manages it automatically), so no ATS exceptions are needed. HTTPS is required for `huggingface.co`.

### 2. Check Network Entitlements
The `HomeHub.entitlements` file currently includes:
```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.cz.keksiczek.homehub.shared</string>
</array>
```

No explicit network entitlements are configured, which is correct for normal HTTPS access to public APIs.

## Testing the Fix

Once models are verified/updated, test the download pipeline:

1. **Manual Test (CLI)**:
   ```bash
   # After verifying repos exist, try accessing them via HF API
   # (will still fail from CLI due to Cloudflare, but succeeds in app)
   curl -H "User-Agent: iPhone" https://huggingface.co/api/models/mlx-community/Llama-3.2-1B-Instruct-4bit
   ```

2. **In-App Test**:
   - Open Settings → Models
   - Tap "Download" on a model
   - Watch for errors in the download pipeline
   - Check `ModelDownloadService.log` for detailed error messages

3. **Unit Test** (Add to test suite):
   ```swift
   func test_modelCatalogReposAreAccessible() async {
       let catalog = ModelCatalogService()
       for model in catalog.models where model.format == .mlx {
           let (isAccessible, statusCode) = try await probeHuggingFaceRepo(model.repoId ?? "")
           XCTAssertTrue(isAccessible, "Repo \(model.displayName) returned \(statusCode)")
       }
   }
   ```

## Priority Actions

1. **Verify repository existence** (manual via browser or HF CLI)
2. **Update URLs** with correct repository names
3. **Consider `mlx://` scheme** for cleaner URLs
4. **Add test** to CI/CD pipeline to catch future repo breakage
5. **Document fallback models** if some repos are permanently unavailable

## Current Workaround for Users

Users can import custom models using the "Add from URL" sheet:
- **For MLX models**: `mlx://organization/repo-name`
- **For GGUF models**: Direct download URL (e.g., `https://...model.gguf`)

This allows circumventing catalog issues for specific models the user knows exist.

---

**Last Updated**: May 2026
**Status**: Investigation complete; awaiting repo verification
