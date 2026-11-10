#!/bin/sh
# One-time: make a fresh account-creation link for the Powvy Note web app and show it as a QR code
# to scan with the iPad camera. Replaces the SETUP_KEY secret; only works while no account exists.
set -e
cd "$(dirname "$0")/.."
DIR=$(mktemp -d)
KEY=$(openssl rand -hex 32)
printf %s "$KEY" | npx wrangler secret put SETUP_KEY --config cloud/wrangler.jsonc
URL="https://powvy-note.zhixuanlucasfeng.workers.dev/#setup=$KEY"
cat > "$DIR/ipad-setup.html" <<EOF
<!doctype html><meta charset="utf-8"><title>Powvy Note · iPad 创建账号</title>
<style>body{font:18px system-ui;background:#151413;color:#eee;display:grid;place-items:center;min-height:100vh;margin:0;text-align:center}#q{background:#fff;padding:18px;display:inline-block;border-radius:8px}p{max-width:520px;line-height:1.6}</style>
<h1>用 iPad 相机扫这个二维码</h1><div id="q"></div>
<p>在 Safari 里打开，设置用户名和密码（至少 12 位），把恢复码存好。<br>建好账号后这个链接就没用了。看完关掉这个页面即可。</p>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<script>new QRCode(document.getElementById('q'),{text:"$URL",width:320,height:320,correctLevel:QRCode.CorrectLevel.M})</script>
EOF
chmod 600 "$DIR/ipad-setup.html"
open "$DIR/ipad-setup.html"
echo "二维码已在浏览器打开。用完可以删掉：rm -r $DIR"
