# `src/common/`

Cross-cutting helpers shared by every module under `src/modules/`.
Mirrors `zfinal/examples/ruoyi-gen/src/common/`:

- `response.zig` — uniform `err` / `ok` / `okNoContent` envelopes,
  `parseIntId` / `parseStringId` / `queryParam` / `requireQuery` /
  `render` helpers. Every handler in `src/modules/<name>/handler.zig`
  should use these instead of inlining `ctx.res_status = .…; try ctx.renderJson(.{ .@"error" = … });`.
- `pagination.zig` — `parsePage` / `parseSize` / `parseSinceSeq` /
  `parse` for the `?page=`, `?size=`, `?since_seq=` query params.
- `validation.zig` — `requireField` / `optionalField` / `isValidEmail`
  / `validateJson` for request-body validation.

Error code ranges (cheap convention):
- `40001..40009` — path / query parameter errors
- `40010..40019` — pagination errors
- `40020..40029` — body field errors
- `40030..40039` — body parse errors
- `40401..40409` — not found
- `40901..40909` — conflict
- `50001..50009` — internal server error
