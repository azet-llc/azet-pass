// Runs in the page (MAIN world). Hands navigator.credentials passkey requests to AZET Pass; when AZET Pass
// says "not mine" (locked, declined, unsupported) the browser's own passkey sheet runs as before.
(() => {
  const c = navigator.credentials;
  if (!c || window.__azetPassWebAuthn) return;
  window.__azetPassWebAuthn = true;
  const orig = { create: c.create.bind(c), get: c.get.bind(c) };
  const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf instanceof ArrayBuffer ? buf : buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const bytes = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (ch) => ch.charCodeAt(0)).buffer;
  let seq = 0;

  function ask(kind, req) {
    const id = "azetpk" + ++seq + Math.random().toString(36).slice(2);
    return new Promise((resolve) => {
      const on = (e) => {
        if (e.source !== window || e.data?.azetPasskeyReply !== id) return;
        window.removeEventListener("message", on);
        resolve(e.data.result);
      };
      window.addEventListener("message", on);
      window.postMessage({ azetPasskey: kind, id, req }, location.origin);
    });
  }

  function credential(r, kind) {
    const resp = kind === "create"
      ? Object.assign(Object.create(AuthenticatorAttestationResponse.prototype), {})
      : Object.assign(Object.create(AuthenticatorAssertionResponse.prototype), {});
    const define = (o, props) => { for (const [k, v] of Object.entries(props)) Object.defineProperty(o, k, { value: v, enumerable: true }); };
    if (kind === "create") {
      define(resp, { clientDataJSON: bytes(r.clientDataJSON), attestationObject: bytes(r.attestationObject),
        getTransports: () => r.transports, getAuthenticatorData: () => bytes(r.authenticatorData),
        getPublicKey: () => bytes(r.publicKey), getPublicKeyAlgorithm: () => r.publicKeyAlgorithm });
    } else {
      define(resp, { clientDataJSON: bytes(r.clientDataJSON), authenticatorData: bytes(r.authenticatorData),
        signature: bytes(r.signature), userHandle: r.userHandle ? bytes(r.userHandle) : null });
    }
    const cred = Object.create(PublicKeyCredential.prototype);
    define(cred, { id: r.id, rawId: bytes(r.rawId), type: "public-key", response: resp, authenticatorAttachment: r.authenticatorAttachment,
      getClientExtensionResults: () => (kind === "create" ? { credProps: { rk: true } } : {}),
      toJSON: () => ({ id: r.id, rawId: r.rawId, type: "public-key", authenticatorAttachment: r.authenticatorAttachment, response: { ...r }, clientExtensionResults: {} }) });
    return cred;
  }

  const es256 = (params) => !params?.length || params.some((p) => p.alg === -7);

  c.create = async function (options) {
    const pk = options?.publicKey;
    if (!pk || !es256(pk.pubKeyCredParams) || options.signal?.aborted) return orig.create(options);
    const req = { rp: { id: pk.rp?.id || location.hostname, name: pk.rp?.name }, user: { id: b64u(pk.user.id), name: pk.user.name, displayName: pk.user.displayName },
      challenge: b64u(pk.challenge), exclude: (pk.excludeCredentials || []).map((x) => b64u(x.id)) };
    const r = await ask("create", req);
    return r?.response ? credential(r.response, "create") : orig.create(options);
  };

  c.get = async function (options) {
    const pk = options?.publicKey;
    if (!pk || options.mediation === "conditional" || options.signal?.aborted) return orig.get(options);
    const req = { rpId: pk.rpId || location.hostname, challenge: b64u(pk.challenge), allow: (pk.allowCredentials || []).map((x) => b64u(x.id)) };
    const r = await ask("get", req);
    return r?.response ? credential(r.response, "get") : orig.get(options);
  };
})();
