"""Signs in to a locally served AZET Pass web vault (headless, our own build on 127.0.0.1) and checks the vault shows
the item the CLI stored. Email, password and item name come from the environment. Prints screen text only.
usage: EMAIL=… MASTER=… ITEM=… python3 webvault-login.py https://127.0.0.1:<port>"""
import asyncio, os, re, sys
from playwright.async_api import async_playwright
base, email, master, item = sys.argv[1], os.environ["EMAIL"], os.environ["MASTER"], os.environ["ITEM"]


async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await (await browser.new_context(ignore_https_errors=True, locale="en-US")).new_page()
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)[:160]))
        page.on("console", lambda m: m.type == "error" and errors.append(re.sub(r"access_token=[^ '\"]+", "access_token=(hidden)", m.text)[:200]))
        text = lambda: page.evaluate("document.body.innerText.replace(/\\s+/g, ' ').slice(0, 300)")
        await page.goto(base + "/#/login"); await page.wait_for_selector("input[type=email]", timeout=60000)
        print("login page:", await text())
        await page.fill("input[type=email]", email)
        await page.get_by_role("button", name=re.compile("^continue$", re.I)).click()
        await page.wait_for_selector("input[type=password]", timeout=30000)
        await page.fill("input[type=password]", master)
        await page.press("input[type=password]", "Enter")
        try:
            await page.get_by_text(item).first.wait_for(timeout=60000)
            seen = True
        except Exception:
            seen = False
        body = await page.evaluate("document.body.innerText")
        print("after login:", re.sub(r"\s+", " ", body).replace(master, "(hidden)")[:300])
        print("old name on screen:", len(re.findall("bitwarden", body, re.I)), "· page errors:", errors[:6])
        print("WEB RESULT: item seen=" + ("ok" if seen else "FAIL"))
        await browser.close()

asyncio.run(main())
