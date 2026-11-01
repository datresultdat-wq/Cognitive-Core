# 依存監査（2026-10-31、修正前と同じルートlockfile）

npm audit: 27件（critical 1 / high 16 / moderate 6 / low 4）。27個のパッケージ指摘であり27個の独立した脆弱性とは限らない。ルート依存は今回変更していない。

bundle列はdry-run source mapへの含有。含有は悪用可能性の証明ではなく、非含有も開発PCのリスクを除外しない。ランタイム経路の侵入テストは未実施。

|パッケージ|深刻度|直接依存|bundle source数|修正影響|
|---|---|---|---:|---|
|@ai-sdk/gateway|low|間接|23|通常更新候補・回帰検証要|
|@ai-sdk/provider-utils|low|間接|80|通常更新候補・回帰検証要|
|@hono/node-server|moderate|間接|0|通常更新候補・回帰検証要|
|@modelcontextprotocol/sdk|high|直接|28|agents 0.32への破壊的更新候補・MCP/DO互換検証要|
|@vitest/mocker|moderate|間接|0|通常更新候補・回帰検証要|
|agents|high|直接|31|agents 0.32への破壊的更新候補・MCP/DO互換検証要|
|ai|low|直接|124|通常更新候補・回帰検証要|
|body-parser|high|間接|0|通常更新候補・回帰検証要|
|esbuild|low|間接|0|通常更新候補・回帰検証要|
|express-rate-limit|moderate|間接|0|通常更新候補・回帰検証要|
|fast-uri|high|間接|3|通常更新候補・回帰検証要|
|hono|high|間接|0|通常更新候補・回帰検証要|
|ip-address|high|間接|0|通常更新候補・回帰検証要|
|js-yaml|high|間接|0|通常更新候補・回帰検証要|
|miniflare|high|間接|0|通常更新候補・回帰検証要|
|nanoid|high|間接|2|通常更新候補・回帰検証要|
|postcss|moderate|間接|0|通常更新候補・回帰検証要|
|proxy-addr|critical|間接|0|通常更新候補・回帰検証要|
|qs|moderate|間接|0|通常更新候補・回帰検証要|
|sharp|high|間接|0|通常更新候補・回帰検証要|
|source-map-js|high|間接|0|通常更新候補・回帰検証要|
|undici|high|間接|0|通常更新候補・回帰検証要|
|vite|high|間接|0|通常更新候補・回帰検証要|
|vitest|moderate|直接|0|通常更新候補・回帰検証要|
|wrangler|high|直接|2|通常更新候補・回帰検証要|
|ws|high|間接|0|通常更新候補・回帰検証要|
|zod|high|直接|95|通常更新候補・回帰検証要|

criticalのproxy-addrは今回Worker bundleには含まれない。ExpressのIP信頼判定経路が対象。SDK・agents・zod等はbundleに含まれ、認証後のMCP入力検証/セッション/HTTP処理等は追加レビューが必要。SDK重複による既知TS2416も未解消。npm audit fix --forceは実行していない。

本番のRLS INFO 10件は閉鎖テーブルに対応。ポリシー追加はしていない。[Supabase説明](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)

## 監査元リンク（npm auditが返した一次アドバイザリ）

- [@ai-sdk/provider-utils has an Uncontrolled Resource Consumption issue](https://github.com/advisories/GHSA-866g-f22w-33x8)
- [Node.js Adapter for Hono: Path traversal in `serve-static` on Windows via encoded backslash (`%5C`)](https://github.com/advisories/GHSA-frvp-7c67-39w9)
- [@hono/node-server: `serveStatic` decodes the request path a second time, leading to bypass of middleware on static paths](https://github.com/advisories/GHSA-rmxm-3fg6-px4f)
- [@modelcontextprotocol/sdk has cross-client data leak via shared server/transport instance reuse](https://github.com/advisories/GHSA-345p-7cg4-v4c7)
- [Model Context Protocol (MCP) TypeScript SDK does not enable DNS rebinding protection by default](https://github.com/advisories/GHSA-w48q-cv73-mx4w)
- [Anthropic's MCP TypeScript SDK has a ReDoS vulnerability](https://github.com/advisories/GHSA-8r9q-7v3j-jr4g)
- [MCP TypeScript SDK: OAuth client could send credentials to an authorization server chosen by the MCP server](https://github.com/advisories/GHSA-6qxp-vccf-f47h)
- [MCP TypeScript SDK: Experimental tasks were not tied to the session that created them](https://github.com/advisories/GHSA-22jm-h49p-29qw)
- [MCP TypeScript client SDK: HTTP client transports and OAuth requests followed cross-origin redirects and re-sent custom headers and request bodies](https://github.com/advisories/GHSA-6prh-2h8m-c8cw)
- [MCP TypeScript SDK: One HTTP request within the default size limit could exhaust server memory during validation](https://github.com/advisories/GHSA-46jr-4wx8-v453)
- [MCP TypeScript SDK: Server bearer authentication accepted tokens issued for another service](https://github.com/advisories/GHSA-rvq5-wwqv-78pq)
- [MCP TypeScript SDK: HTTP server transports and handlers did not limit request body size or JSON-RPC batch length](https://github.com/advisories/GHSA-f897-62hf-6gxq)
- [Vitest: Path Traversal / Arbitrary File Read via @vitest/mocker Redirect Mock](https://github.com/advisories/GHSA-82fw-gwwq-j7x9)
- [Vitest: Code injection via unauthenticated manual mock registration](https://github.com/advisories/GHSA-qxg6-89mg-rqv8)
- [Cloudflare Agents SDK has Insecure Direct Object Reference (IDOR) via Header-Based Email Routing](https://github.com/advisories/GHSA-r7x9-8ph7-w8cg)
- [Cloudflare Agents is Vulnerable to Reflected Cross-Site Scripting in the AI Playground's OAuth callback handler](https://github.com/advisories/GHSA-cvhv-6xm6-c3v4)
- [Cloudflare Agents has a Reflected Cross-Site Scripting (XSS) vulnerability in AI Playground site](https://github.com/advisories/GHSA-w5cr-2qhr-jqc5)
- [body-parser vulnerable to denial of service when invalid limit value silently disables size enforcement](https://github.com/advisories/GHSA-v422-hmwv-36x6)
- [body-parser vulnerable to Denial of Service via trailing bytes after a compressed request body](https://github.com/advisories/GHSA-27r3-jxmh-p828)
- [esbuild allows arbitrary file read when running the development server on Windows](https://github.com/advisories/GHSA-g7r4-m6w7-qqqr)
- [fast-uri vulnerable to host confusion via literal backslash authority delimiter](https://github.com/advisories/GHSA-v2hh-gcrm-f6hx)
- [fast-uri vulnerable to host confusion via backslash authority introducer](https://github.com/advisories/GHSA-7p8r-x3mc-p8w7)
- [fast-uri vulnerable to path traversal via percent-encoded dot segments](https://github.com/advisories/GHSA-q3j6-qgpj-74h6)
- [fast-uri vulnerable to host confusion via percent-encoded authority delimiters](https://github.com/advisories/GHSA-v39h-62p7-jpjc)
- [fast-uri vulnerable to server-side request forgery via malformed IPv6 normalization](https://github.com/advisories/GHSA-f65p-4m7j-42xc)
- [fast-uri vulnerable to host confusion via percent-encoded scheme normalization](https://github.com/advisories/GHSA-jqff-g426-hqxp)
- [fast-uri vulnerable to host confusion via failed IDN canonicalization](https://github.com/advisories/GHSA-4c8g-83qw-93j6)
- [fast-uri vulnerable to authority injection via an unvalidated port in serialize](https://github.com/advisories/GHSA-qw65-cvwx-89v3)
- [fast-uri vulnerable to inconsistent host case normalization via percent-encoded octets](https://github.com/advisories/GHSA-hrr3-gc8f-f4qj)
- [fast-uri vulnerable to URI scheme spoofing via percent-encoded scheme decoding](https://github.com/advisories/GHSA-w74x-v6f9-j3xg)
- [fast-uri vulnerable to improper path equivalence in relative reference normalization](https://github.com/advisories/GHSA-xhq7-xmqj-769h)
- [fast-uri vulnerable to scheme injection via an unescaped first-segment colon in suffix references](https://github.com/advisories/GHSA-333x-w4r6-6crp)
- [Hono has CSS Declaration Injection via Style Object Values in JSX SSR](https://github.com/advisories/GHSA-qp7p-654g-cw7p)
- [Hono has improper validation of NumericDate claims (exp, nbf, iat) in JWT verify()](https://github.com/advisories/GHSA-hm8q-7f3q-5f36)
- [Hono's Cache Middleware ignores Vary: Authorization / Vary: Cookie leading to cross-user cache leakage](https://github.com/advisories/GHSA-p77w-8qqv-26rm)
- [Hono: bodyLimit() can be bypassed for chunked / unknown-length requests](https://github.com/advisories/GHSA-9vqf-7f2p-gf9v)
- [hono/jsx has Unvalidated JSX Tag Names that May Allow HTML Injection](https://github.com/advisories/GHSA-69xw-7hcm-h432)
- [Hono: IP Restriction bypasses static deny rules for non-canonical IPv6 ](https://github.com/advisories/GHSA-xrhx-7g5j-rcj5)
- [Hono: Cookie helper does not sanitize sameSite and priority, allowing Set-Cookie injection](https://github.com/advisories/GHSA-3hrh-pfw6-9m5x)
- [Hono: JWT middleware accepts any Authorization scheme, not only Bearer](https://github.com/advisories/GHSA-f577-qrjj-4474)
- [Hono: app.mount() strips mount prefix using undecoded path, causing incorrect routing for percent-encoded paths](https://github.com/advisories/GHSA-2gcr-mfcq-wcc3)
- [hono Improperly Handles JSX Attribute Names Allows HTML Injection in hono/jsx SSR](https://github.com/advisories/GHSA-458j-xx4x-4375)
- [hono: Body Limit Middleware can be bypassed on AWS Lambda by understating `Content-Length`](https://github.com/advisories/GHSA-rv63-4mwf-qqc2)
- [hono: Lambda@Edge adapter keeps only the last value of a repeated request header, dropping the rest](https://github.com/advisories/GHSA-wgpf-jwqj-8h8p)
- [hono: CORS Middleware reflects any Origin with credentials when `origin` defaults to the wildcard](https://github.com/advisories/GHSA-88fw-hqm2-52qc)
- [hono: Path traversal in `serve-static` on Windows via encoded backslash (`%5C`)](https://github.com/advisories/GHSA-wwfh-h76j-fc44)
- [hono: AWS Lambda adapter merges multiple `Set-Cookie` headers into one value, dropping cookies on ALB single-header and Lattice](https://github.com/advisories/GHSA-j6c9-x7qj-28xf)
- [Hono: API Gateway v1 adapter can drop a distinct repeated request header value during de-duplication](https://github.com/advisories/GHSA-xgm2-5f3f-mvvc)
- [hono/jsx does not isolate context per request, leading to cross-request data disclosure](https://github.com/advisories/GHSA-hvrm-45r6-mjfj)
- [Hono: Server-Side XSS via JSX Escaping Bypass in cx() Utility](https://github.com/advisories/GHSA-w62v-xxxg-mg59)
- [Hono: ReDoS in CORS middleware via Access-Control-Request-Headers](https://github.com/advisories/GHSA-8j4g-w8fx-2239)
- [Hono: `memo()` retains SSR output across requests, leading to cross-user data disclosure](https://github.com/advisories/GHSA-f23p-vx2j-j53r)
- [Hono: Proxy Helper does not remove response headers listed in the `Connection` header](https://github.com/advisories/GHSA-79qm-7rj5-m7r9)
- [Hono: Algorithmic Complexity DoS in Language Middleware](https://github.com/advisories/GHSA-54fx-42gc-7vw4)
- [Hono: Incomplete fix for CVE-2026-39408: `toSSG()` still writes files outside the output directory](https://github.com/advisories/GHSA-gqvv-2mrq-wpjv)
- [Hono: Unbounded dot-notation nesting in `parseBody()` can cause memory exhaustion](https://github.com/advisories/GHSA-g6gw-c38x-mqfc)
- [Hono: Query parser reads parameters after the URL fragment, causing cache-key and proxy interpretation differentials](https://github.com/advisories/GHSA-crvj-82cr-hjcx)
- [hono/jsx renders plain strings unescaped in boundary components, leading to XSS](https://github.com/advisories/GHSA-hxh3-vqpv-xpqv)
- [Hono: `serveStatic` decodes the request path a second time, leading to bypass of middleware on static paths](https://github.com/advisories/GHSA-5r4p-p66f-jhc7)
- [ip-address has XSS in Address6 HTML-emitting methods](https://github.com/advisories/GHSA-v2v4-37r5-5v8g)
- [ip-address: Address4 decodes leading-zero octets as decimal while resolvers decode them as octal, allowing SSRF and trust-boundary bypass](https://github.com/advisories/GHSA-mwp4-54f8-5fhr)
- [ip-address: Address6.isLinkLocal() recognizes fe80::/64 rather than fe80::/10, allowing SSRF and trust-boundary bypass to on-link hosts](https://github.com/advisories/GHSA-rpw4-54j3-4h4q)
- [ip-address: isInSubnet() and isHostInSubnet() compare addresses of different families as if they shared an address space, allowing an allowlist check to admit an address outside its range](https://github.com/advisories/GHSA-j6r3-76f7-8jcv)
- [ip-address: Address6 builds a parse diagnostic proportional to the input with no length bound, allowing a single long string to stall or crash the process](https://github.com/advisories/GHSA-h3mg-xc3c-68pw)
- [ip-address: Address6 matches a zone identifier in quadratic time ahead of its length limit, allowing a single long string to stall the process](https://github.com/advisories/GHSA-rxp7-6hxx-x8q5)
- [JS-YAML: Quadratic-complexity DoS in merge key handling via repeated aliases](https://github.com/advisories/GHSA-h67p-54hq-rp68)
- [js-yaml: YAML merge-key chains can force quadratic CPU consumption](https://github.com/advisories/GHSA-52cp-r559-cp3m)
- [JS-YAML: Quadratic CPU consumption in !!omap resolution (3.x and 4.x) — CVE-2026-59870 fix not backported](https://github.com/advisories/GHSA-5p4m-2wfm-xmqj)
- [js-yaml: maxTotalMergeKeys does not limit CPU use for empty merge sources](https://github.com/advisories/GHSA-2883-xcg3-v3hh)
- [nanoid: non-secure generators can loop indefinitely with negative size](https://github.com/advisories/GHSA-28wg-ghj8-5hjv)
- [nanoid: custom generators can loop indefinitely when size is zero](https://github.com/advisories/GHSA-2v37-7h3g-55p8)
- [nanoid: Integer Overflow or Wraparound](https://github.com/advisories/GHSA-xwg4-73v4-xw9w)
- [PostCSS: incomplete fix of GHSA-6g55-p6wh-862q — attacker-controlled sourceMappingURL reads arbitrary .map files when `from` is unset](https://github.com/advisories/GHSA-fxqj-rqcc-2cmp)
- [proxy-addr vulnerable to IP spoofing via IPv4-mapped IPv6 trust subnet](https://github.com/advisories/GHSA-jqcg-44mw-7w3h)
- [qs has a remotely triggerable DoS: qs.stringify crashes with TypeError on null/undefined entries in comma-format arrays when encodeValuesOnly is set](https://github.com/advisories/GHSA-q8mj-m7cp-5q26)
- [qs array-limit bypass via bracket-key comma parsing](https://github.com/advisories/GHSA-x5fp-wj9c-mxmx)
- [qs: Denial of Service via Attacker Controlled isBuffer](https://github.com/advisories/GHSA-4mjr-xmp4-gh2g)
- [qs : qs.stringify with arrayFormat 'comma' throws an uncaught TypeError on array elements carrying a non-callable own toString (DoS)](https://github.com/advisories/GHSA-6pq8-jhm2-2vcw)
- [sharp inherited vulnerabilities in libvips: CVE-2026-33327, CVE-2026-33328, CVE-2026-35590, CVE-2026-35591](https://github.com/advisories/GHSA-f88m-g3jw-g9cj)
- [sharp: Vulnerabilities in libheif: GHSA-g89c-p67h-r497 and GHSA-2jg2-4ch7-h545](https://github.com/advisories/GHSA-rgj7-g3m4-5g8c)
- [sharp : Vulnerability in librsvg dependency CVE-2026-96889](https://github.com/advisories/GHSA-wq5f-xc86-pv6w)
- [source-map-js allows event-loop denial of service through indexed source-map section offsets](https://github.com/advisories/GHSA-68fv-2mgg-jv7q)
- [undici vulnerable to TLS certificate validation bypass via dropped requestTls in SOCKS5 ProxyAgent](https://github.com/advisories/GHSA-vmh5-mc38-953g)
- [undici vulnerable to HTTP header injection via Set-Cookie percent-decoding](https://github.com/advisories/GHSA-p88m-4jfj-68fv)
- [undici WebSocket client vulnerable to denial of service via fragment count bypass](https://github.com/advisories/GHSA-vxpw-j846-p89q)
- [undici vulnerable to cross-origin request routing via SOCKS5 proxy pool reuse](https://github.com/advisories/GHSA-hm92-r4w5-c3mj)
- [undici vulnerable to Set-Cookie SameSite attribute downgrade via permissive substring matching](https://github.com/advisories/GHSA-g8m3-5g58-fq7m)
- [undici vulnerable to cross-user information disclosure via shared cache whitespace bypass](https://github.com/advisories/GHSA-pr7r-676h-xcf6)
- [undici vulnerable to downstream response desynchronization via retry interceptor](https://github.com/advisories/GHSA-8xcm-r25x-g524)
- [undici vulnerable to cross-user information disclosure and parse-time crash via degenerate private cache directives](https://github.com/advisories/GHSA-4cwx-7wf7-3272)
- [undici vulnerable to CRLF Injection via blob-like body 'type' property](https://github.com/advisories/GHSA-m8rv-5g2x-5cg5)
- [undici vulnerable to cross-user information disclosure via whitespace around equals in Cache-Control directives](https://github.com/advisories/GHSA-jr45-8vmc-qm54)
- [undici vulnerable to cookie attribute injection via unsanitized domain and unparsed setCookie fields](https://github.com/advisories/GHSA-v3r7-h72x-cjcm)
- [undici vulnerable to HTTP response queue poisoning via keep-alive socket reuse](https://github.com/advisories/GHSA-35p6-xmwp-9g52)
- [undici vulnerable to Denial of Service via orphaned RetryHandler response body](https://github.com/advisories/GHSA-pmjh-fq2x-6v4x)
- [undici vulnerable to downstream response splitting via retry interceptor](https://github.com/advisories/GHSA-r53p-7pc4-xj5r)
- [undici vulnerable to Denial of Service via unrequested WebSocket subprotocol](https://github.com/advisories/GHSA-rfgv-xxqx-mfg5)
- [undici vulnerable to Denial of Service via unbounded decompression of compressed responses](https://github.com/advisories/GHSA-3xpg-4rpp-hhhm)
- [undici vulnerable to cross-user cookie disclosure via Set-Cookie caching in shared caches](https://github.com/advisories/GHSA-2jfj-6hjv-fm6j)
- [undici vulnerable to response truncation via oversized chunked responses in the dump interceptor](https://github.com/advisories/GHSA-2gqq-gqf2-x968)
- [undici vulnerable to TLS certificate validation bypass via dropped connect options in BalancedPool](https://github.com/advisories/GHSA-w293-vg96-wgc3)
- [undici vulnerable to caching and replay of unsafe HTTP method responses](https://github.com/advisories/GHSA-8436-99hf-9mmv)
- [undici vulnerable to Denial of Service via WebSocketStream unclean close](https://github.com/advisories/GHSA-rx4f-c7p8-82vq)
- [undici vulnerable to Denial of Service via unbounded memory in the EventSource parser](https://github.com/advisories/GHSA-4qv8-2p9j-2685)
- [undici vulnerable to Subresource Integrity bypass via non-lowercase algorithm tokens](https://github.com/advisories/GHSA-f72v-6w45-q472)
- [undici vulnerable to Denial of Service via unhandled error on excessive content-encodings](https://github.com/advisories/GHSA-xjj6-f33q-929c)
- [undici vulnerable to cache poisoning and cross-user disclosure via cross-origin redirects](https://github.com/advisories/GHSA-4w7w-5xrc-9h26)
- [undici vulnerable to TLS certificate validation bypass via dropped tls options in Agent](https://github.com/advisories/GHSA-2m5v-pch6-74hx)
- [undici vulnerable to Denial of Service via TLS 1.2 certificate-changing renegotiation](https://github.com/advisories/GHSA-qrxm-fqhp-jwvm)
- [undici WebSocket client vulnerable to Denial of Service via unbounded automatic PONG buffering](https://github.com/advisories/GHSA-9fm3-97px-rjf6)
- [undici vulnerable to Denial of Service via unhandled exception in the decompress interceptor](https://github.com/advisories/GHSA-55wc-3pg8-jfw6)
- [launch-editor: escapeCmdArgs() omits % escaping on Windows](https://github.com/advisories/GHSA-698v-4r3x-3vcv)
- [launch-editor: Editor CLI flag misinterpretation causing arbitrary command execution for some editors](https://github.com/advisories/GHSA-r825-w8mm-5pxw)
- [launch-editor: `fs.existsSync()` existence check can be bypassed on Windows](https://github.com/advisories/GHSA-587h-7wmj-h5pm)
- [Vite: Cross origin script execution through Vite custom middleware](https://github.com/advisories/GHSA-9jrq-w75r-8gcw)
- [Vite: Files outside `server.fs.allow` could be served when project paths match system paths on non-Windows machine](https://github.com/advisories/GHSA-rq7h-c2jc-7f22)
- [ws: Uninitialized memory disclosure](https://github.com/advisories/GHSA-58qx-3vcg-4xpx)
- [ws: Memory exhaustion DoS from tiny fragments and data chunks](https://github.com/advisories/GHSA-96hv-2xvq-fx4p)
- [Zod can exhaust memory while validating oversized constrained collections](https://github.com/advisories/GHSA-mrhx-c7xc-m3w5)
