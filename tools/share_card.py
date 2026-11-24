# -*- coding: utf-8 -*-
"""生成一张可直接转发到微信/QQ 的分享卡（含两个二维码）。

用法（仓库根目录）：
    python tools/share_card.py
    python tools/share_card.py --out D:/somewhere/card.png

版本号与安装包大小都从仓库里读，不用手改：
  · 版本号 ← pubspec.yaml 的 `version:`
  · 体积   ← build/app/outputs/flutter-apk/app-release.apk（不存在就省略体积）

二维码指向：
  1) /releases/latest        —— 每次发版自动指向最新，适合长期转发
  2) 当前版本的 APK 直链     —— 一点就下，适合急用

依赖：pip install qrcode pillow
"""
import argparse
import os
import re
import sys

import qrcode
from PIL import Image, ImageDraw, ImageFont
from qrcode.constants import ERROR_CORRECT_Q

W, H = 1080, 1680
MARGIN = 96
BG = (250, 247, 242)
INK = (31, 27, 25)
SUB = (122, 112, 106)
LINE = (222, 212, 202)
CARD = (255, 255, 255)
ACCENT = (140, 90, 60)

REPO = "xia259214-beep/morning-app"
PAGE_URL = f"https://github.com/{REPO}/releases/latest"
BOLD = "C:/Windows/Fonts/msyhbd.ttc"
REG = "C:/Windows/Fonts/msyh.ttc"


def f(path, size):
    return ImageFont.truetype(path, size)


def read_version(root):
    txt = open(os.path.join(root, "pubspec.yaml"), encoding="utf-8").read()
    m = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)", txt, re.M)
    if not m:
        raise SystemExit("pubspec.yaml 里找不到 version")
    return m.group(1)


def read_size(root):
    apk = os.path.join(root, "build/app/outputs/flutter-apk/app-release.apk")
    if not os.path.exists(apk):
        return ""
    mb = os.path.getsize(apk) / (1024 * 1024)
    return f"{mb:.1f} MB"


def qr_img(url, px):
    """px 是可用边长。整数倍放大，避免模块宽窄不均导致扫不出来。"""
    q = qrcode.QRCode(version=None, error_correction=ERROR_CORRECT_Q, box_size=1, border=2)
    q.add_data(url)
    q.make(fit=True)
    modules = q.modules_count + 4  # 含 2 格白边
    k = max(1, px // modules)
    q2 = qrcode.QRCode(version=q.version, error_correction=ERROR_CORRECT_Q, box_size=k, border=2)
    q2.add_data(url)
    q2.make(fit=True)
    img = q2.make_image(fill_color=INK, back_color=CARD).convert("RGB")
    assert max(img.size) <= px, (img.size, px)
    return img


def center_text(d, text, font, y, fill):
    w = d.textlength(text, font=font)
    d.text(((W - w) / 2, y), text, font=font, fill=fill)


def wrap(d, text, font, max_w):
    """按像素宽度断行（中文逐字断）。"""
    lines, cur = [], ""
    for ch in text:
        if d.textlength(cur + ch, font=font) <= max_w:
            cur += ch
        else:
            lines.append(cur)
            cur = ch
    if cur:
        lines.append(cur)
    return lines


def build(root, out):
    version = read_version(root)
    size = read_size(root)
    apk_url = f"https://github.com/{REPO}/releases/download/v{version}/morning-v{version}.apk"

    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0, W, 8], fill=ACCENT)
    center_text(d, "A N D R O I D   ·   智 能 闹 钟  +  晨 间 闭 环", f(REG, 22), 96, SUB)
    center_text(d, "晨序 MORNING", f(BOLD, 86), 148, INK)
    center_text(d, "唤醒 → 答题 → 新闻播报 → 打卡", f(REG, 34), 272, SUB)

    chip = f"v{version}    ·    {size + '    ·    ' if size else ''}Android 8.0 以上"
    cf = f(REG, 26)
    cw = d.textlength(chip, font=cf)
    d.rounded_rectangle([(W - cw) / 2 - 34, 336, (W + cw) / 2 + 34, 402], radius=33,
                        fill=(243, 233, 223), outline=LINE)
    d.text(((W - cw) / 2, 354), chip, font=cf, fill=ACCENT)

    BOX, GAP, Y = 400, 36, 452
    x1 = (W - BOX * 2 - GAP) / 2
    cards = (
        (x1, PAGE_URL, "打开下载页", "版本说明 + 下载按钮"),
        (x1 + BOX + GAP, apk_url, "直接下安装包", f"v{version}" + (f" · {size}" if size else "")),
    )
    for i, (x, url, label, hint) in enumerate(cards):
        d.rounded_rectangle([x, Y, x + BOX, Y + BOX], radius=28, fill=CARD, outline=LINE, width=2)
        # 右上角标占 64px；二维码再缩一圈，保证静区完整不被压住。
        # v1.19.0 的 APK 直链比旧版长，二维码模块更密，静区少一点就扫不出来。
        q = qr_img(url, BOX - 140)
        img.paste(q, (int(x + (BOX - q.size[0]) / 2), int(Y + (BOX - q.size[1]) / 2)))
        d.ellipse([x + BOX - 64, Y + 16, x + BOX - 18, Y + 62], fill=ACCENT)
        num = str(i + 1)
        nw = d.textlength(num, font=f(BOLD, 26))
        d.text((x + BOX - 41 - nw / 2, Y + 23), num, font=f(BOLD, 26), fill=CARD)
        lf = f(BOLD, 34)
        lw = d.textlength(label, font=lf)
        d.text((x + (BOX - lw) / 2, Y + BOX + 26), label, font=lf, fill=INK)
        hf = f(REG, 23)
        hw = d.textlength(hint, font=hf)
        d.text((x + (BOX - hw) / 2, Y + BOX + 76), hint, font=hf, fill=SUB)

    d.line([MARGIN, 1004, W - MARGIN, 1004], fill=LINE, width=2)

    tips = [
        ("装之前", "手机上先允许「安装未知来源应用」。小米、华为等会弹风险提示，选「仍要安装」即可。"),
        ("换手机", "老版本的数据在「我的 → 数据备份」里导出成 JSON，新机导入就行，闹钟、打卡、答题记录都不会丢。"),
        ("有问题", "到仓库的 Issues 留言，写上版本号和手机型号，我按这个排查。"),
    ]
    ty = 1052
    tf = f(REG, 25)
    for k, v in tips:
        d.text((MARGIN, ty), k, font=f(BOLD, 26), fill=ACCENT)
        ty += 42
        for line in wrap(d, v, tf, W - MARGIN * 2):
            d.text((MARGIN, ty), line, font=tf, fill=INK)
            ty += 36
        ty += 22

    center_text(d, f"github.com/{REPO}", f(REG, 24), H - 122, SUB)
    center_text(d, "仅 Android · 数据全在本机，不上传服务器", f(REG, 22), H - 80, SUB)

    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out, quality=95)
    print(f"saved {out}  {img.size[0]}x{img.size[1]}  v{version}")


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=os.path.join(root, "build/share/晨序MORNING_分享卡.png"))
    a = p.parse_args()
    sys.exit(build(root, a.out))
