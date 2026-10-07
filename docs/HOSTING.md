# Hosting the launcher on klaudik.com

`irm https://klaudik.com/win | iex` downloads whatever `https://klaudik.com/win` returns and runs it. That URL must serve the `win.ps1` attached to the current GitHub release.

## Requirements

- Serve the file itself. Do **not** redirect to GitHub: the pinned checksum inside `win.ps1` only adds protection if it is served from a different place than the release file.
- Deploy the `win.ps1` **from the GitHub release**, never one built on your own machine. The release workflow checks that the launcher attached to the release pins the hash of the published `WinKit.ps1`; a local build may differ by a single uncommitted change, and every user would then get "Checksum mismatch".
- HTTPS only. Redirect `http://` to `https://` and send `Strict-Transport-Security` (ideally preloaded), because people often type the command without `https://`.
- `Content-Type: text/plain; charset=utf-8` and `X-Content-Type-Options: nosniff`.
- Short caching (`Cache-Control: max-age=300`), and purge any CDN cache after deploying, so a new release reaches users quickly.
- Update it only after the GitHub release for that version is published; otherwise the launcher points to a file that does not exist yet.

## Deploying a release

```powershell
$tag = 'v1.0.0'
Invoke-WebRequest "https://github.com/klaudikdev/winkit/releases/download/$tag/win.ps1" -OutFile win.ps1 -UseBasicParsing
```

Then publish that `win.ps1` at `/win`.

## Examples

**Static file.** Copy the release's `win.ps1` to your web root as `win` (no extension) and configure the server to send it as `text/plain; charset=utf-8`.

**nginx**

```nginx
location = /win {
    default_type text/plain;
    charset utf-8;
    add_header Cache-Control "public, max-age=300";
    add_header X-Content-Type-Options nosniff;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    alias /var/www/klaudik/winkit/win.ps1;
}
```

**Next.js / Vercel** (`public/win.ps1` plus a rewrite in `next.config.js`)

```js
async rewrites() {
  return [{ source: '/win', destination: '/win.ps1' }];
},
async headers() {
  return [{ source: '/win', headers: [
    { key: 'Content-Type', value: 'text/plain; charset=utf-8' },
    { key: 'Cache-Control', value: 'public, max-age=300' },
    { key: 'X-Content-Type-Options', value: 'nosniff' },
  ]}];
},
```

## Checking the deployment

This compares what klaudik.com serves with the file on GitHub, the same way the launcher does:

```powershell
$tag = 'v1.0.0'
$response = Invoke-WebRequest https://klaudik.com/win -UseBasicParsing
$response.Headers['Content-Type']                       # text/plain; charset=utf-8
$live = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
$pinned = ([regex]::Match($live, "expected = '([0-9A-F]{64})'")).Groups[1].Value
$file = Join-Path $env:TEMP 'winkit-check.ps1'
Invoke-WebRequest "https://github.com/klaudikdev/winkit/releases/download/$tag/WinKit.ps1" -OutFile $file -UseBasicParsing
$actual = (Get-FileHash $file -Algorithm SHA256).Hash
"pinned: $pinned"
"actual: $actual"
$pinned -eq $actual                                     # must be True
```
