#!/usr/bin/env python3
"""在 Chromium 中验证生产卡片模板的布局与七种配色；原生交互另由模拟器测试覆盖。"""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request

SOURCE = Path('ios/ShareExtension/ShareImageDocument.swift').read_text()
THEMES = ['classic', 'light', 'dark', 'black', 'blue', 'green', 'mojian']
VARIABLES = [('bg', 'background'), ('card', 'card'), ('text', 'text'), ('strong', 'strongText'),
             ('secondary', 'secondaryText'), ('border', 'border'), ('accent', 'accent'),
             ('code-bg', 'codeBackground'), ('inline-code-bg', 'inlineCodeBackground'),
             ('avatar-bg', 'avatarBackground'), ('quote-line', 'quoteLine')]


def palette(name):
    values = {}
    for css, prop in VARIABLES:
        block = SOURCE.split(f'var {prop}: String {{', 1)[1].split('\n    }', 1)[0]
        for cases, value in re.findall(r'case ([^:]+): return "([^"]+)"', block):
            if f'.{name}' in [part.strip() for part in cases.split(',')]:
                values[css] = value
                break
        assert css in values, (name, prop)
    return values


def fixture():
    base = re.search(r'private static let baseCSS = #"""\n(.*?)\n    """#', SOURCE, re.S)[1]
    mojian = re.search(r'private static let mojianCSS = #"""\n(.*?)\n    """#', SOURCE, re.S)[1]
    rules = '\n'.join('html[data-theme="' + theme + '"]{' + ''.join(
        f'--{key}:{value};' for key, value in palette(theme).items()) + '}' for theme in THEMES)
    template = re.search(r'        return """\n(.*?)\n        """', SOURCE, re.S)[1]
    text = '<p>完整正文测试，配色切换后仍保留。</p>' * 40
    text += '<pre><code>' + 'long_identifier_' * 60 + '</code></pre>'
    text += '<table><tr><td>' + 'https://example.invalid/' * 20 + '</td></tr></table><p>END_MARKER</p>'
    values = {'palette.themeKey': 'classic', 'ShareImagePalette.css': base + rules + mojian,
              'title': '长图与即时配色回归', 'site': 'LINUX DO', 'source': 'https://linux.do/t/test/123/1',
              'brandDate': '<span class="brand-date">10月26日</span>', 'display': '测试作者',
              'classicMeta': '@reader · 刚刚', 'mojianMeta': ' · 刚刚', 'content': text,
              'avatar': '<div class="avatar avatar-fallback">测</div>'}
    for key in ['logoSVG', 'linkIconSVG']:
        values[key] = re.search(r'private static let ' + key + r' = """\n(.*?)\n    """', SOURCE, re.S)[1]
    template = re.sub(r'\\\(([^)]+)\)', lambda match: values[match[1]], template)
    return template.replace('\\"', '"')


def main():
    with tempfile.TemporaryDirectory(prefix='fluxdo-card-') as directory:
        page = Path(directory) / 'card.html'
        page.write_text(fixture())
        driver = subprocess.Popen(['chromedriver', '--port=19583', '--allowed-ips=127.0.0.1'],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        session = None

        def call(method, path, body=None):
            data = None if body is None else json.dumps(body).encode()
            request = urllib.request.Request('http://127.0.0.1:19583' + path, data=data, method=method,
                                             headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.load(response)['value']
            if isinstance(result, dict) and 'error' in result:
                raise AssertionError(result)
            return result

        def script(code, *args):
            return call('POST', f'/session/{session}/execute/sync', {'script': code, 'args': args})

        try:
            for _ in range(100):
                try:
                    call('GET', '/status')
                    break
                except OSError:
                    time.sleep(.1)
            session = call('POST', '/session', {'capabilities': {'alwaysMatch': {
                'browserName': 'chrome', 'goog:chromeOptions': {'args': ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage']}
            }}})['sessionId']
            call('POST', f'/session/{session}/url', {'url': page.as_uri()})
            for width, height in [(375, 812), (768, 1024)]:
                call('POST', f'/session/{session}/goog/cdp/execute', {
                    'cmd': 'Emulation.setDeviceMetricsOverride',
                    'params': {'width': width, 'height': height, 'deviceScaleFactor': 1, 'mobile': width < 500}})
                initial = script('return document.querySelector(".content").innerHTML')
                for theme in THEMES:
                    values = palette(theme)
                    script('''const root=document.documentElement;
                        root.setAttribute('data-theme',arguments[0]);
                        for(const [key,value] of Object.entries(arguments[1])) root.style.setProperty('--'+key,value);
                        return true;''', theme, values)
                    result = script('''return {width:document.body.getBoundingClientRect().width,
                        height:document.body.getBoundingClientRect().height,
                        overflow:document.documentElement.scrollWidth>window.innerWidth,
                        bg:getComputedStyle(document.body).backgroundColor,
                        title:getComputedStyle(document.querySelector('.title')).fontSize,
                        content:document.querySelector('.content').innerHTML,
                        end:document.body.textContent.includes('END_MARKER')};''')
                    rgb = tuple(int(values['bg'][index:index + 2], 16) for index in (1, 3, 5))
                    assert result['bg'] == 'rgb(%d, %d, %d)' % rgb, (theme, result)
                    assert result['width'] == 375 and not result['overflow'], (width, theme, result)
                    assert result['end'] and result['content'] == initial and result['height'] > height
                    assert result['title'] == ('21px' if theme == 'mojian' else '16px')
                print(f'通过：{width}×{height} 实际模板七色即时更新、长正文末尾、无横向截断、墨笺版式')
        finally:
            if session:
                call('DELETE', f'/session/{session}')
            driver.terminate()
            driver.wait(timeout=10)


if __name__ == '__main__':
    main()
