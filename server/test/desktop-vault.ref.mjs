// prints what a {{azet-pass:…}} reference resolves to, through the reader named in AZET_BROWSER_SECRET_CMD
const m = await import(process.env.HOME + "/Code/azet-browser/daemon/azet-browser.mjs");
try { console.log(m.fromPass(process.env.REF)); } catch (e) { console.log("ERR " + e.message); }
process.exit(0);
