"""End-to-end test of the dashboard in demo mode (synthetic items, browser storage only).

Usage:  pip install playwright==1.56.0 && playwright install chromium;  python tests/test_ui.py [screenshot_dir]
"""
import functools
import http.server
import sys
import threading
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SHOTS = Path(sys.argv[1]) if len(sys.argv) > 1 else None


def serve():
    h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(ROOT))
    h.log_message = lambda *a: None
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}/"


def main():
    srv, base = serve()
    results, errors = [], []

    def check(name, ok, detail=""):
        results.append(ok)
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"   [{detail}]"))

    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1280, "height": 900}, accept_downloads=True)
        pg = ctx.new_page()
        pg.on("pageerror", lambda e: errors.append(str(e)))
        pg.on("console", lambda m: errors.append(m.text) if m.type == "error" and "fonts" not in m.text else None)

        pg.goto(base)
        pg.wait_for_selector("h1")
        check("unconfigured site explains itself", "Not configured" in pg.inner_text("main"), pg.inner_text("main")[:80])

        pg.goto(base + "?demo")
        pg.wait_for_selector("#email")
        check("sign-in page shown", pg.is_visible("#email"))
        pg.fill("#email", "Tester@Example.org")
        pg.click("button[type=submit]")
        pg.wait_for_selector("#agree")
        check("consent required before rating", pg.is_disabled("#go"))
        pg.goto(base + "?demo#/evaluate/1")
        pg.wait_for_selector("#agree")
        check("cannot reach items without consent", pg.is_visible("#agree"))
        pg.check("#agree")
        pg.click("#go")
        pg.wait_for_selector("text=Item 1 of 6")
        check("after consent, item 1 opens", True)
        if SHOTS:
            pg.screenshot(path=str(SHOTS / "ui_item_desktop.png"), full_page=True)

        def rate(adeq_a, adeq_b, flu_a, flu_b, orth=True):
            pg.click(f'[data-field=adequacy_a] button[data-v="{adeq_a}"]')
            pg.click(f'[data-field=adequacy_b] button[data-v="{adeq_b}"]')
            pg.click(f'[data-field=fluency_a] button[data-v="{flu_a}"]')
            pg.click(f'[data-field=fluency_b] button[data-v="{flu_b}"]')
            if orth:
                pg.click('[data-field=orthography_a] button[data-v="Correct"]')
                pg.click('[data-field=orthography_b] button[data-v="Major diacritic errors"]')
            pg.click('[data-field=preference] button[data-v="A better"]')
            pg.select_option("#err", "Diacritics / orthography")

        rate("5 - all meaning preserved", "4 - most meaning", "5 - flawless", "4 - good")
        pg.fill("#cmt", "Synthetic test comment, with a tab\there.")
        pg.wait_for_function("document.querySelector('#st').textContent.includes('Complete')", timeout=5000)
        check("item 1 complete and saved", "Complete" in pg.inner_text("#st"), pg.inner_text("#st"))
        check("pressed state shown", pg.get_attribute('[data-field=preference] button[data-v="A better"]', "aria-pressed") == "true")
        pg.click("#next")
        pg.wait_for_selector("text=Item 2 of 6")
        pg.click("#prev")
        pg.wait_for_selector("text=Item 1 of 6")
        check("ratings persist when navigating back",
              pg.get_attribute('[data-field=adequacy_b] button[data-v="4 - most meaning"]', "aria-pressed") == "true")
        pg.reload()
        pg.wait_for_selector("text=Item 1 of 6")
        check("ratings persist after reload", pg.input_value("#cmt").startswith("Synthetic test comment"))

        pg.goto(base + "?demo#/evaluate/3")      # Yoruba -> English item
        pg.wait_for_selector("text=Item 3 of 6")
        check("English output: orthography fixed to Not applicable",
              pg.is_disabled('[data-field=orthography_a] button') and
              pg.get_attribute('[data-field=orthography_a] button', "aria-pressed") == "true")
        rate("3 - much meaning", "2 - little meaning", "4 - good", "3 - non-native", orth=False)
        pg.check("#disp")
        pg.wait_for_function("document.querySelector('#st').textContent.includes('Complete')", timeout=5000)
        check("English-output item completes without orthography input", "Complete" in pg.inner_text("#st"))
        pg.keyboard.press("Alt+ArrowRight")
        pg.wait_for_selector("text=Item 4 of 6")
        check("keyboard shortcut moves to next item", True)

        pg.goto(base + "?demo#/progress")
        pg.wait_for_selector(".cells")
        done = pg.locator(".cells a.done").count()
        check("progress shows 2 complete items", done == 2, str(done))
        if SHOTS:
            pg.screenshot(path=str(SHOTS / "ui_progress.png"), full_page=True)

        pg.goto(base + "?demo#/admin")
        pg.wait_for_selector("button[data-r]")
        with pg.expect_download() as dl:
            pg.click("button[data-r]")
        path = dl.value.path()
        raw = Path(path).read_bytes()
        text = raw.decode("utf-8-sig")
        lines = text.strip("\n").split("\n")
        header = lines[0].split("\t")
        check("export starts with UTF-8 byte-order mark", raw.startswith(b"\xef\xbb\xbf"))
        check("export has workbook columns", header[:2] == ["Item ID", "Comparison"] and header[-1] == "Comment" and len(header) == 16, header)
        check("export has one row per item", len(lines) == 7, len(lines))
        row1 = dict(zip(header, lines[1].split("\t")))
        check("export row 1 carries the ratings", row1["Preference"] == "A better" and row1["Adequacy A"] == "5 - all meaning preserved", row1)
        check("tabs in comments are flattened", row1["Comment"] == "Synthetic test comment, with a tab here.", row1["Comment"])
        check("Yoruba text intact in export", "Ṣọ́ra bí o bá ń yan àwòrán ìdánimọ̀." in text)
        if SHOTS:
            pg.screenshot(path=str(SHOTS / "ui_admin.png"), full_page=True)

        mob = b.new_context(viewport={"width": 390, "height": 844}, color_scheme="dark")
        mp = mob.new_page()
        mp.goto(base + "?demo")
        mp.wait_for_selector("#email")
        mp.fill("#email", "m@example.org"); mp.click("button[type=submit]")
        mp.wait_for_selector("#agree"); mp.check("#agree"); mp.click("#go")
        mp.wait_for_selector("text=Item 1 of 6")
        overflow = mp.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1")
        check("no horizontal scroll on a phone", not overflow)
        if SHOTS:
            mp.screenshot(path=str(SHOTS / "ui_item_mobile_dark.png"), full_page=True)
        check("no JavaScript errors", not errors, errors[:3])
        b.close()
    srv.shutdown()
    print(f"\n{sum(results)}/{len(results)} interface checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
