# Brand assets

- `logo.svg`: the Job Apply logo, a copy of `apps/web/public/logo.svg` in Job-apply-enterprise-application. It shows an application document, a check (approved by you), and a spark (AI assistance).
- `logo-email.png`: a 96×96 render of the same logo, for emails (shown at 48×48). Email clients can't display SVG.

When the logo changes, re-render the PNG from the SVG. The S3 key includes the file's hash, so the URL changes and no client shows a cached old logo.
