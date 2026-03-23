from flask import Flask, Response, render_template_string, jsonify, send_from_directory
import time
import os
import glob
import subprocess

app = Flask(__name__)

# --- Configuration ---
BASE_DIR = "/opt/usbscan/logs"
ARCHIVE_DIR = "/opt/usbscan/logs/archives"

# --- Hardware Port Mapping ---
# Loaded from /etc/aegis/ports.conf (written by installer / aegis-detect-ports)
def _load_port_config():
    conf = "/etc/aegis/ports.conf"
    defaults = {
        "AEGIS_PORT_A": "",
        "AEGIS_PORT_C": "",
    }
    if not os.path.exists(conf):
        return defaults
    try:
        with open(conf) as f:
            for line in f:
                line = line.strip()
                if line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if key in defaults:
                    defaults[key] = val
    except Exception:
        pass
    return defaults

_port_cfg = _load_port_config()
PORT_A_ID = _port_cfg["AEGIS_PORT_A"]
PORT_C_ID = _port_cfg["AEGIS_PORT_C"]

HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MTS AEGIS // USB THREAT ANALYSIS SYSTEM</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Rajdhani:wght@300;400;500;600;700&display=swap');

  :root {
    --bg-void:       #030507;
    --bg-deep:       #060c10;
    --bg-panel:      #080e14;
    --bg-surface:    #0c1520;
    --bg-elevated:   #0f1e2e;
    --border-dim:    #0d2030;
    --border-mid:    #143248;
    --border-glow:   #1a4060;
    --cyan:          #00d4ff;
    --cyan-dim:      #0099bb;
    --cyan-ghost:    rgba(0,212,255,0.08);
    --cyan-glow:     rgba(0,212,255,0.35);
    --green:         #00ff88;
    --green-dim:     #00aa55;
    --green-ghost:   rgba(0,255,136,0.08);
    --red:           #ff4c4c;
    --red-dim:       #cc2222;
    --red-ghost:     rgba(255,76,76,0.08);
    --amber:         #ffaa00;
    --amber-ghost:   rgba(255,170,0,0.08);
    --text-bright:   #d0e8f0;
    --text-mid:      #6a9ab0;
    --text-dim:      #2a4a5a;
    --text-ghost:    #142030;
    --font-mono:     'Share Tech Mono', monospace;
    --font-ui:       'Rajdhani', sans-serif;
    --scan-color:    var(--cyan);
    --scan-ghost:    var(--cyan-ghost);
    --scan-glow:     var(--cyan-glow);
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  html, body {
    height: 100%; width: 100%;
    background: var(--bg-void);
    color: var(--text-bright);
    font-family: var(--font-ui);
    overflow: hidden;
  }

  /* ─── SCANLINE OVERLAY ─── */
  body::before {
    content: '';
    position: fixed; inset: 0;
    background: repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(0,0,0,0.08) 2px,
      rgba(0,0,0,0.08) 4px
    );
    pointer-events: none;
    z-index: 9999;
  }

  /* ─── NOISE TEXTURE ─── */
  body::after {
    content: '';
    position: fixed; inset: 0;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)' opacity='0.04'/%3E%3C/svg%3E");
    pointer-events: none;
    z-index: 9998;
    opacity: 0.5;
  }

  /* ─── LAYOUT ─── */
  #app {
    display: grid;
    grid-template-columns: 280px 1fr 260px;
    grid-template-rows: 52px 1fr;
    height: 100vh;
    gap: 0;
  }

  /* ─── TOP BAR ─── */
  #topbar {
    grid-column: 1 / -1;
    background: var(--bg-deep);
    border-bottom: 1px solid var(--border-mid);
    display: flex;
    align-items: center;
    padding: 0 20px;
    gap: 20px;
    position: relative;
    z-index: 10;
  }

  #topbar::after {
    content: '';
    position: absolute;
    bottom: -1px; left: 0; right: 0;
    height: 1px;
    background: linear-gradient(90deg, transparent, var(--cyan), var(--cyan-dim), transparent);
    opacity: 0.4;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: var(--font-ui);
    font-weight: 700;
    font-size: 16px;
    letter-spacing: 3px;
    color: var(--cyan);
    text-transform: uppercase;
    white-space: nowrap;
  }

  .brand-icon {
    width: 28px; height: 28px;
    position: relative;
    flex-shrink: 0;
  }

  .brand-icon svg { width: 100%; height: 100%; }

  .brand-sep {
    width: 1px; height: 28px;
    background: var(--border-mid);
    margin: 0 4px;
  }

  .brand-sub {
    font-size: 9px;
    letter-spacing: 4px;
    color: var(--text-mid);
    font-weight: 400;
  }

  .topbar-spacer { flex: 1; }

  .sys-indicator {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 10px;
    letter-spacing: 2px;
    color: var(--text-dim);
    font-family: var(--font-mono);
  }

  .sys-dot {
    width: 6px; height: 6px;
    border-radius: 50%;
    background: var(--green);
    box-shadow: 0 0 6px var(--green);
    animation: sys-blink 3s ease-in-out infinite;
  }

  @keyframes sys-blink {
    0%, 90%, 100% { opacity: 1; }
    95% { opacity: 0.3; }
  }

  #clock {
    font-family: var(--font-mono);
    font-size: 12px;
    color: var(--text-mid);
    letter-spacing: 2px;
    min-width: 80px;
    text-align: right;
  }

  /* ─── LEFT PANEL (HISTORY) ─── */
  #panel-left {
    background: var(--bg-panel);
    border-right: 1px solid var(--border-mid);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .panel-header {
    padding: 14px 16px 10px;
    display: flex;
    align-items: center;
    gap: 8px;
    border-bottom: 1px solid var(--border-dim);
    flex-shrink: 0;
  }

  .panel-title {
    font-size: 10px;
    letter-spacing: 3px;
    color: var(--text-mid);
    font-weight: 600;
    text-transform: uppercase;
  }

  .panel-badge {
    background: var(--border-mid);
    color: var(--text-mid);
    font-size: 9px;
    padding: 1px 5px;
    border-radius: 2px;
    font-family: var(--font-mono);
    margin-left: auto;
  }

  #history-list {
    flex: 1;
    overflow-y: auto;
    padding: 4px 0;
  }

  #history-list::-webkit-scrollbar { width: 3px; }
  #history-list::-webkit-scrollbar-track { background: transparent; }
  #history-list::-webkit-scrollbar-thumb { background: var(--border-mid); border-radius: 2px; }

  .h-item {
    padding: 9px 14px;
    cursor: pointer;
    border-left: 2px solid transparent;
    transition: all 0.15s;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .h-item:hover {
    background: var(--bg-surface);
    border-left-color: var(--cyan-dim);
  }

  .h-item-date {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--text-mid);
  }

  .h-tag {
    font-size: 8px;
    font-weight: 700;
    letter-spacing: 2px;
    padding: 2px 6px;
    border-radius: 2px;
    font-family: var(--font-mono);
  }

  .h-tag-clean {
    color: var(--green);
    background: var(--green-ghost);
    border: 1px solid rgba(0,255,136,0.2);
  }

  .h-tag-infected {
    color: var(--red);
    background: var(--red-ghost);
    border: 1px solid rgba(255,76,76,0.2);
  }

  /* ─── ACTIONS AT BOTTOM OF LEFT PANEL ─── */
  #actions-panel {
    padding: 12px;
    border-top: 1px solid var(--border-dim);
    display: flex;
    flex-direction: column;
    gap: 8px;
    flex-shrink: 0;
  }

  .action-btn {
    width: 100%;
    padding: 10px 14px;
    border: 1px solid;
    border-radius: 3px;
    font-family: var(--font-ui);
    font-weight: 700;
    font-size: 11px;
    letter-spacing: 2px;
    text-transform: uppercase;
    cursor: pointer;
    transition: all 0.2s;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 8px;
    position: relative;
    overflow: hidden;
  }

  .action-btn::before {
    content: '';
    position: absolute;
    top: 0; left: -100%;
    width: 100%; height: 100%;
    background: linear-gradient(90deg, transparent, rgba(255,255,255,0.05), transparent);
    transition: left 0.4s;
  }

  .action-btn:hover::before { left: 100%; }

  #transfer-btn {
    background: var(--green-ghost);
    border-color: rgba(0,255,136,0.3);
    color: var(--green);
  }

  #transfer-btn:not(:disabled):hover {
    background: rgba(0,255,136,0.15);
    border-color: var(--green);
    box-shadow: 0 0 12px rgba(0,255,136,0.2);
  }

  #transfer-btn:disabled {
    opacity: 0.3;
    cursor: not-allowed;
    color: var(--text-dim);
    border-color: var(--border-dim);
    background: transparent;
  }

  #format-btn {
    background: var(--red-ghost);
    border-color: rgba(255,76,76,0.25);
    color: var(--red-dim);
  }

  #format-btn:hover {
    background: rgba(255,76,76,0.12);
    border-color: var(--red);
    color: var(--red);
    box-shadow: 0 0 12px rgba(255,76,76,0.2);
  }

  /* ─── MAIN CENTER ─── */
  #panel-main {
    background: var(--bg-deep);
    display: flex;
    flex-direction: column;
    overflow: hidden;
    position: relative;
  }

  /* ─── HARDWARE STATUS ─── */
  #hw-bar {
    display: flex;
    gap: 12px;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-dim);
    flex-shrink: 0;
  }

  .port-module {
    flex: 1;
    background: var(--bg-panel);
    border: 1px solid var(--border-dim);
    border-radius: 4px;
    padding: 10px 14px;
    display: flex;
    align-items: center;
    gap: 12px;
    transition: all 0.5s cubic-bezier(0.4, 0, 0.2, 1);
    position: relative;
    overflow: hidden;
  }

  .port-module::before {
    content: '';
    position: absolute;
    inset: 0;
    background: linear-gradient(135deg, transparent 60%, rgba(0,212,255,0.03));
    opacity: 0;
    transition: opacity 0.5s;
  }

  .port-module.connected::before { opacity: 1; }

  .port-module.connected {
    border-color: rgba(0,212,255,0.4);
    background: rgba(0,20,35,0.9);
    box-shadow: 0 0 20px rgba(0,212,255,0.08), inset 0 0 20px rgba(0,212,255,0.03);
  }

  /* USB Shape Rendering */
  .usb-viz {
    flex-shrink: 0;
    position: relative;
  }

  /* Type-A */
  .usb-a-shell {
    width: 36px; height: 18px;
    border: 2px solid var(--border-mid);
    border-radius: 2px;
    background: var(--bg-void);
    position: relative;
    transition: all 0.4s;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .usb-a-inner {
    width: 20px; height: 7px;
    background: var(--bg-void);
    border: 1px solid var(--border-dim);
    border-radius: 1px;
    transition: all 0.4s;
  }

  .usb-a-pin {
    width: 3px; height: 12px;
    background: var(--border-mid);
    position: absolute;
    right: -4px; top: 50%;
    transform: translateY(-50%);
    transition: all 0.4s;
  }

  /* Type-C */
  .usb-c-shell {
    width: 28px; height: 14px;
    border: 2px solid var(--border-mid);
    border-radius: 8px;
    background: var(--bg-void);
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: all 0.4s;
  }

  .usb-c-inner {
    width: 14px; height: 5px;
    background: var(--border-dim);
    border-radius: 3px;
    transition: all 0.4s;
  }

  .usb-c-pin {
    width: 3px; height: 8px;
    background: var(--border-mid);
    position: absolute;
    right: -4px; top: 50%;
    transform: translateY(-50%);
    transition: all 0.4s;
  }

  .connected .usb-a-shell,
  .connected .usb-c-shell {
    border-color: var(--cyan);
    box-shadow: 0 0 8px var(--cyan-glow), inset 0 0 5px rgba(0,212,255,0.1);
  }

  .connected .usb-a-inner { background: rgba(0,212,255,0.2); border-color: var(--cyan-dim); }
  .connected .usb-c-inner { background: rgba(0,212,255,0.2); }
  .connected .usb-a-pin,
  .connected .usb-c-pin { background: var(--cyan); box-shadow: 0 0 4px var(--cyan); }

  .port-info { flex: 1; }

  .port-label {
    font-size: 9px;
    letter-spacing: 3px;
    color: var(--text-dim);
    font-weight: 600;
    text-transform: uppercase;
    margin-bottom: 2px;
  }

  .port-state {
    font-size: 11px;
    letter-spacing: 1px;
    color: var(--text-dim);
    font-family: var(--font-mono);
    transition: all 0.3s;
  }

  .connected .port-state {
    color: var(--cyan);
  }

  .port-led {
    width: 7px; height: 7px;
    border-radius: 50%;
    background: var(--border-mid);
    transition: all 0.5s;
    flex-shrink: 0;
  }

  .connected .port-led {
    background: var(--cyan);
    box-shadow: 0 0 8px var(--cyan), 0 0 16px rgba(0,212,255,0.4);
    animation: led-pulse 2s ease-in-out infinite;
  }

  @keyframes led-pulse {
    0%, 100% { box-shadow: 0 0 8px var(--cyan), 0 0 16px rgba(0,212,255,0.4); }
    50% { box-shadow: 0 0 4px var(--cyan), 0 0 8px rgba(0,212,255,0.2); }
  }

  /* ─── STATUS DISPLAY ─── */
  #status-section {
    padding: 10px 16px;
    border-bottom: 1px solid var(--border-dim);
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 12px;
  }

  #status-badge {
    padding: 6px 18px;
    font-family: var(--font-ui);
    font-size: 18px;
    font-weight: 700;
    letter-spacing: 5px;
    text-transform: uppercase;
    border-radius: 3px;
    border: 1px solid;
    transition: all 0.5s;
    flex-shrink: 0;
  }

  .status-WAITING {
    color: var(--text-dim) !important;
    border-color: var(--border-mid) !important;
    background: transparent !important;
  }

  .status-SCANNING {
    color: var(--cyan) !important;
    border-color: var(--cyan-dim) !important;
    background: var(--cyan-ghost) !important;
    box-shadow: 0 0 20px rgba(0,212,255,0.1) !important;
    animation: status-scan-pulse 1.5s ease-in-out infinite !important;
  }

  @keyframes status-scan-pulse {
    0%, 100% { box-shadow: 0 0 15px rgba(0,212,255,0.1); }
    50% { box-shadow: 0 0 30px rgba(0,212,255,0.25), inset 0 0 20px rgba(0,212,255,0.05); }
  }

  .status-CLEAN {
    color: var(--green) !important;
    border-color: rgba(0,255,136,0.4) !important;
    background: var(--green-ghost) !important;
    box-shadow: 0 0 25px rgba(0,255,136,0.15) !important;
  }

  .status-INFECTED {
    color: var(--red) !important;
    border-color: rgba(255,76,76,0.5) !important;
    background: var(--red-ghost) !important;
    box-shadow: 0 0 30px rgba(255,76,76,0.2) !important;
    animation: threat-pulse 0.8s ease-in-out infinite !important;
  }

  @keyframes threat-pulse {
    0%, 100% { box-shadow: 0 0 20px rgba(255,76,76,0.2); }
    50% { box-shadow: 0 0 40px rgba(255,76,76,0.4), inset 0 0 20px rgba(255,76,76,0.08); }
  }

  .status-ERROR {
    color: var(--amber) !important;
    border-color: rgba(255,170,0,0.4) !important;
    background: var(--amber-ghost) !important;
  }

  .status-FORMATTING {
    color: var(--amber) !important;
    border-color: rgba(255,170,0,0.4) !important;
    background: var(--amber-ghost) !important;
    box-shadow: 0 0 20px rgba(255,170,0,0.1) !important;
    animation: status-scan-pulse 1.2s ease-in-out infinite !important;
  }

  #status-meta {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  #status-label {
    font-size: 10px;
    letter-spacing: 2px;
    color: var(--text-dim);
    font-weight: 600;
  }

  #status-detail {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--text-mid);
    min-height: 14px;
  }

  /* Heartbeat indicator */
  #heartbeat-ring {
    width: 24px; height: 24px;
    border-radius: 50%;
    border: 1.5px solid var(--border-mid);
    position: relative;
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    opacity: 0;
    transition: opacity 0.3s;
  }

  #heartbeat-ring.active {
    border-color: var(--cyan);
    opacity: 1;
    animation: hb-ring 1s ease-out infinite;
  }

  #heartbeat-ring::after {
    content: '';
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--cyan);
  }

  @keyframes hb-ring {
    0% { box-shadow: 0 0 0 0 rgba(0,212,255,0.5); }
    70% { box-shadow: 0 0 0 8px rgba(0,212,255,0); }
    100% { box-shadow: 0 0 0 0 rgba(0,212,255,0); }
  }

  /* ─── PROGRESS BAR ─── */
  #progress-section {
    padding: 0 16px 8px;
    flex-shrink: 0;
    display: none;
  }

  #progress-section.visible { display: block; }

  .progress-track {
    width: 100%;
    height: 3px;
    background: var(--border-dim);
    border-radius: 2px;
    overflow: visible;
    position: relative;
  }

  #progress-fill {
    height: 100%;
    background: linear-gradient(90deg, var(--cyan-dim), var(--cyan), #00ffee);
    border-radius: 2px;
    width: 0%;
    transition: width 0.4s cubic-bezier(0.4, 0, 0.2, 1);
    position: relative;
    box-shadow: 0 0 8px var(--cyan-glow);
  }

  #progress-fill::after {
    content: '';
    position: absolute;
    right: -1px; top: -2px;
    width: 7px; height: 7px;
    border-radius: 50%;
    background: var(--cyan);
    box-shadow: 0 0 8px var(--cyan), 0 0 16px var(--cyan-glow);
  }

  #progress-label {
    font-family: var(--font-mono);
    font-size: 9px;
    color: var(--text-dim);
    letter-spacing: 1px;
    margin-top: 4px;
    text-align: right;
  }

  /* ─── TERMINAL ─── */
  #terminal-wrapper {
    flex: 1;
    overflow: hidden;
    position: relative;
    padding: 0 16px 16px;
  }

  #terminal-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 0 8px;
    flex-shrink: 0;
  }

  .term-dot {
    width: 8px; height: 8px;
    border-radius: 50%;
  }

  #terminal {
    height: 100%;
    background: var(--bg-void);
    border: 1px solid var(--border-dim);
    border-radius: 3px;
    padding: 14px;
    overflow-y: auto;
    font-family: var(--font-mono);
    font-size: 11.5px;
    line-height: 1.7;
    color: #4a7a90;
    word-break: break-all;
    position: relative;
  }

  #terminal::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 40px;
    background: linear-gradient(to bottom, var(--bg-void), transparent);
    pointer-events: none;
    z-index: 2;
  }

  #terminal::-webkit-scrollbar { width: 3px; }
  #terminal::-webkit-scrollbar-track { background: transparent; }
  #terminal::-webkit-scrollbar-thumb { background: var(--border-mid); }

  #terminal .line { display: block; }
  #terminal .line-new {
    animation: line-appear 0.15s ease-out forwards;
  }

  @keyframes line-appear {
    from { opacity: 0; transform: translateX(-4px); }
    to { opacity: 1; transform: translateX(0); }
  }

  .term-idle {
    text-align: center;
    padding-top: 30%;
    color: var(--text-ghost);
    font-size: 11px;
    letter-spacing: 3px;
  }

  /* ─── RIGHT PANEL ─── */
  #panel-right {
    background: var(--bg-panel);
    border-left: 1px solid var(--border-mid);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .metrics-section {
    padding: 14px 14px 10px;
    border-bottom: 1px solid var(--border-dim);
  }

  .metrics-title {
    font-size: 9px;
    letter-spacing: 3px;
    color: var(--text-dim);
    font-weight: 600;
    margin-bottom: 10px;
  }

  .metric-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 5px 0;
    border-bottom: 1px solid var(--text-ghost);
  }

  .metric-row:last-child { border-bottom: none; }

  .metric-key {
    font-size: 9px;
    letter-spacing: 1px;
    color: var(--text-dim);
    font-family: var(--font-mono);
  }

  .metric-val {
    font-size: 11px;
    color: var(--text-mid);
    font-family: var(--font-mono);
    letter-spacing: 1px;
  }

  /* ─── ALERT PANEL ─── */
  #alert-zone {
    flex: 1;
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .alert-block {
    background: var(--bg-surface);
    border: 1px solid var(--border-dim);
    border-radius: 3px;
    padding: 10px 12px;
    border-left: 3px solid var(--border-mid);
    font-size: 10px;
    color: var(--text-dim);
    font-family: var(--font-mono);
    line-height: 1.5;
    letter-spacing: 0.5px;
  }

  .alert-block.threat { border-left-color: var(--red); color: var(--red-dim); background: var(--red-ghost); }
  .alert-block.ok { border-left-color: var(--green-dim); color: var(--green-dim); background: var(--green-ghost); }
  .alert-block.info { border-left-color: var(--cyan-dim); color: var(--cyan-dim); background: var(--cyan-ghost); }

  /* ─── MODAL OVERLAY ─── */
  #modal-overlay {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(0,0,0,0.85);
    z-index: 1000;
    align-items: center;
    justify-content: center;
    backdrop-filter: blur(3px);
  }

  #modal-overlay.open { display: flex; }

  .modal-box {
    background: var(--bg-panel);
    border: 1px solid rgba(255,76,76,0.4);
    border-radius: 4px;
    padding: 28px 32px;
    max-width: 420px;
    width: 90%;
    box-shadow: 0 0 60px rgba(255,76,76,0.15), 0 0 120px rgba(255,76,76,0.05);
    position: relative;
    overflow: hidden;
  }

  .modal-box::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, transparent, var(--red), transparent);
  }

  .modal-icon {
    font-size: 32px;
    text-align: center;
    margin-bottom: 14px;
    filter: drop-shadow(0 0 8px var(--red));
  }

  .modal-title {
    font-size: 16px;
    font-weight: 700;
    letter-spacing: 3px;
    color: var(--red);
    text-align: center;
    margin-bottom: 8px;
  }

  .modal-sub {
    font-size: 10px;
    letter-spacing: 2px;
    color: var(--text-dim);
    text-align: center;
    margin-bottom: 16px;
  }

  .modal-body {
    font-size: 12px;
    color: var(--text-mid);
    line-height: 1.7;
    background: var(--red-ghost);
    border: 1px solid rgba(255,76,76,0.15);
    border-radius: 3px;
    padding: 12px;
    margin-bottom: 20px;
    font-family: var(--font-mono);
  }

  .modal-actions {
    display: flex;
    gap: 10px;
  }

  .modal-btn {
    flex: 1;
    padding: 10px;
    border-radius: 3px;
    font-family: var(--font-ui);
    font-weight: 700;
    font-size: 11px;
    letter-spacing: 2px;
    cursor: pointer;
    border: 1px solid;
    text-transform: uppercase;
    transition: all 0.2s;
  }

  .modal-btn-cancel {
    background: transparent;
    border-color: var(--border-mid);
    color: var(--text-mid);
  }

  .modal-btn-cancel:hover { border-color: var(--text-mid); }

  .modal-btn-confirm {
    background: var(--red-ghost);
    border-color: var(--red);
    color: var(--red);
  }

  .modal-btn-confirm:hover {
    background: rgba(255,76,76,0.2);
    box-shadow: 0 0 15px rgba(255,76,76,0.3);
  }

  /* ─── CORNER DECORATION ─── */
  .corner-tl, .corner-br {
    position: absolute;
    width: 14px; height: 14px;
    pointer-events: none;
  }

  .corner-tl {
    top: 8px; left: 8px;
    border-top: 1px solid var(--cyan-dim);
    border-left: 1px solid var(--cyan-dim);
    opacity: 0.4;
  }

  .corner-br {
    bottom: 8px; right: 8px;
    border-bottom: 1px solid var(--cyan-dim);
    border-right: 1px solid var(--cyan-dim);
    opacity: 0.4;
  }

  /* ─── OPERATION OVERLAY ─── */
  /* Centred over #panel-main. Appears during format/transfer operations.   */
  /* Uses position:absolute so it doesn't cover the sidebars or topbar.     */
  #op-overlay {
    display: none;
    position: absolute;
    inset: 0;
    z-index: 500;
    background: rgba(3,5,7,0.82);
    backdrop-filter: blur(4px);
    align-items: center;
    justify-content: center;
    flex-direction: column;
    gap: 0;
  }

  #op-overlay.open {
    display: flex;
  }

  .op-box {
    width: 460px;
    background: var(--bg-panel);
    border: 1px solid var(--border-mid);
    border-radius: 4px;
    padding: 32px 36px 28px;
    position: relative;
    overflow: hidden;
  }

  /* Top accent line — colour set via JS */
  .op-box::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: var(--op-accent, var(--cyan));
    opacity: 0.8;
  }

  .op-header {
    display: flex;
    align-items: center;
    gap: 14px;
    margin-bottom: 24px;
  }

  .op-icon {
    width: 36px; height: 36px;
    border-radius: 50%;
    border: 1.5px solid var(--op-accent, var(--cyan));
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    box-shadow: 0 0 12px var(--op-glow, var(--cyan-glow));
    animation: op-icon-pulse 2s ease-in-out infinite;
  }

  @keyframes op-icon-pulse {
    0%, 100% { box-shadow: 0 0 8px var(--op-glow, var(--cyan-glow)); }
    50%  { box-shadow: 0 0 20px var(--op-glow, var(--cyan-glow)); }
  }

  .op-icon svg { width: 18px; height: 18px; }

  .op-title-block { flex: 1; }

  .op-title {
    font-size: 15px;
    font-weight: 700;
    letter-spacing: 3px;
    color: var(--op-accent, var(--cyan));
    text-transform: uppercase;
    line-height: 1.2;
  }

  .op-subtitle {
    font-size: 9px;
    letter-spacing: 2px;
    color: var(--text-dim);
    margin-top: 3px;
    font-family: var(--font-mono);
  }

  /* Indeterminate bar track */
  .op-track {
    width: 100%;
    height: 4px;
    background: var(--border-dim);
    border-radius: 2px;
    overflow: hidden;
    margin-bottom: 10px;
    position: relative;
  }

  /* The sliding fill — infinite left-to-right sweep */
  .op-bar {
    position: absolute;
    top: 0; left: -40%;
    width: 40%;
    height: 100%;
    background: linear-gradient(
      90deg,
      transparent,
      var(--op-accent, var(--cyan)),
      var(--op-accent, var(--cyan)),
      transparent
    );
    border-radius: 2px;
    box-shadow: 0 0 10px var(--op-glow, var(--cyan-glow));
    animation: op-slide 1.6s cubic-bezier(0.4, 0, 0.6, 1) infinite;
  }

  @keyframes op-slide {
    0%   { left: -40%; }
    100% { left: 100%; }
  }

  .op-status-line {
    font-family: var(--font-mono);
    font-size: 10px;
    color: var(--text-dim);
    letter-spacing: 1px;
    min-height: 14px;
    transition: color 0.3s;
  }

  /* Result state — shown after operation completes */
  .op-result {
    display: none;
    margin-top: 18px;
    padding: 12px 14px;
    border-radius: 3px;
    border: 1px solid;
    font-family: var(--font-mono);
    font-size: 11px;
    line-height: 1.6;
  }

  .op-result.ok {
    background: var(--green-ghost);
    border-color: rgba(0,255,136,0.25);
    color: var(--green);
  }

  .op-result.fail {
    background: var(--red-ghost);
    border-color: rgba(255,76,76,0.25);
    color: var(--red);
  }

  .op-dismiss {
    display: none;
    margin-top: 16px;
    width: 100%;
    padding: 9px;
    background: transparent;
    border: 1px solid var(--border-mid);
    border-radius: 3px;
    color: var(--text-mid);
    font-family: var(--font-ui);
    font-weight: 700;
    font-size: 10px;
    letter-spacing: 2px;
    text-transform: uppercase;
    cursor: pointer;
    transition: all 0.2s;
  }

  .op-dismiss:hover {
    border-color: var(--text-mid);
    color: var(--text-bright);
  }

  /* Glitch animation for infected state */
  @keyframes glitch {
    0%, 100% { text-shadow: none; transform: none; }
    92% { text-shadow: 2px 0 var(--red), -2px 0 rgba(0,212,255,0.5); transform: translateX(1px); }
    94% { text-shadow: -2px 0 var(--red), 2px 0 rgba(0,212,255,0.5); transform: translateX(-1px); }
    96% { text-shadow: none; transform: none; }
  }

  body.infected #status-badge {
    animation: threat-pulse 0.8s ease-in-out infinite, glitch 3s linear infinite !important;
  }
</style>
</head>
<body>
<div id="app">

  <!-- TOP BAR -->
  <header id="topbar">
    <div class="brand">
      <div class="brand-icon">
        <svg viewBox="0 0 28 28" fill="none" xmlns="http://www.w3.org/2000/svg">
          <polygon points="14,2 26,8 26,20 14,26 2,20 2,8" stroke="#00d4ff" stroke-width="1.2" fill="rgba(0,212,255,0.06)"/>
          <polygon points="14,6 22,10 22,18 14,22 6,18 6,10" stroke="#00d4ff" stroke-width="0.8" fill="rgba(0,212,255,0.04)" opacity="0.6"/>
          <circle cx="14" cy="14" r="3" fill="#00d4ff" opacity="0.9"/>
          <line x1="14" y1="2" x2="14" y2="6" stroke="#00d4ff" stroke-width="0.8"/>
          <line x1="14" y1="22" x2="14" y2="26" stroke="#00d4ff" stroke-width="0.8"/>
          <line x1="2" y1="8" x2="6" y2="10" stroke="#00d4ff" stroke-width="0.8"/>
          <line x1="22" y1="18" x2="26" y2="20" stroke="#00d4ff" stroke-width="0.8"/>
          <line x1="26" y1="8" x2="22" y2="10" stroke="#00d4ff" stroke-width="0.8"/>
          <line x1="6" y1="18" x2="2" y2="20" stroke="#00d4ff" stroke-width="0.8"/>
        </svg>
      </div>
      MTS AEGIS
      <div class="brand-sep"></div>
      <div class="brand-sub">THREAT ANALYSIS SYSTEM v4.2</div>
    </div>
    <div class="topbar-spacer"></div>
    <div class="sys-indicator">
      <div class="sys-dot"></div>
      SYSTEM NOMINAL
    </div>
    &nbsp;&nbsp;
    <div id="clock">--:--:--</div>
  </header>

  <!-- LEFT PANEL -->
  <aside id="panel-left">
    <div class="panel-header">
      <div class="panel-title">Scan Archives</div>
      <div class="panel-badge" id="hist-count">0</div>
    </div>
    <div id="history-list">
      <div style="padding: 20px; text-align:center; color: var(--text-ghost); font-family: var(--font-mono); font-size:10px; letter-spacing:2px;">LOADING...</div>
    </div>
    <div id="actions-panel">
      <button id="transfer-btn" class="action-btn" onclick="runTransfer()" disabled>
        <span id="transfer-icon">&#9875;</span>
        TRANSFER FILES
      </button>
      <button id="format-btn" class="action-btn" onclick="openFormatModal()">
        <span>&#9888;</span>
        FORMAT DRIVE
      </button>
    </div>
  </aside>

  <!-- MAIN PANEL -->
  <main id="panel-main">
    <div class="corner-tl"></div>
    <div class="corner-br"></div>

    <!-- Operation Overlay (Format / Transfer) -->
    <div id="op-overlay">
      <div class="op-box" id="op-box">
        <div class="op-header">
          <div class="op-icon" id="op-icon">
            <svg id="op-svg" viewBox="0 0 18 18" fill="none" xmlns="http://www.w3.org/2000/svg"></svg>
          </div>
          <div class="op-title-block">
            <div class="op-title" id="op-title">OPERATION</div>
            <div class="op-subtitle" id="op-subtitle">PLEASE WAIT</div>
          </div>
        </div>
        <div class="op-track"><div class="op-bar" id="op-bar"></div></div>
        <div class="op-status-line" id="op-status-line">Initializing...</div>
        <div class="op-result" id="op-result"></div>
        <button class="op-dismiss" id="op-dismiss" onclick="dismissOpOverlay()">DISMISS</button>
      </div>
    </div>

    <!-- Hardware Ports -->
    <div id="hw-bar">
      <div id="port-a" class="port-module">
        <div class="usb-viz">
          <div class="usb-a-shell">
            <div class="usb-a-inner"></div>
          </div>
          <div class="usb-a-pin"></div>
        </div>
        <div class="port-info">
          <div class="port-label">Type-A &bull; Port 1</div>
          <div id="label-a" class="port-state">NO DEVICE</div>
        </div>
        <div class="port-led"></div>
      </div>
      <div id="port-c" class="port-module">
        <div class="usb-viz">
          <div class="usb-c-shell">
            <div class="usb-c-inner"></div>
          </div>
          <div class="usb-c-pin"></div>
        </div>
        <div class="port-info">
          <div class="port-label">Type-C &bull; Port 2</div>
          <div id="label-c" class="port-state">NO DEVICE</div>
        </div>
        <div class="port-led"></div>
      </div>
    </div>

    <!-- Status Row -->
    <div id="status-section">
      <div id="status-badge" class="status-WAITING">WAITING</div>
      <div id="status-meta">
        <div id="status-label">SYSTEM STATUS</div>
        <div id="status-detail">Insert USB device to initiate threat analysis</div>
      </div>
      <div id="heartbeat-ring"></div>
    </div>

    <!-- Progress -->
    <div id="progress-section">
      <div class="progress-track">
        <div id="progress-fill"></div>
      </div>
      <div id="progress-label">0%</div>
    </div>

    <!-- Terminal -->
    <div id="terminal-wrapper">
      <div id="terminal">
        <div class="term-idle" id="term-idle">[ AWAITING SCAN DATA ]</div>
      </div>
    </div>
  </main>

  <!-- RIGHT PANEL -->
  <aside id="panel-right">
    <div class="metrics-section">
      <div class="metrics-title">Session Metrics</div>
      <div class="metric-row">
        <span class="metric-key">SESSION_ID</span>
        <span class="metric-val" id="m-session">—</span>
      </div>
      <div class="metric-row">
        <span class="metric-key">SCANS_RUN</span>
        <span class="metric-val" id="m-scans">0</span>
      </div>
      <div class="metric-row">
        <span class="metric-key">THREATS</span>
        <span class="metric-val" id="m-threats" style="color: var(--text-mid)">0</span>
      </div>
      <div class="metric-row">
        <span class="metric-key">UPTIME</span>
        <span class="metric-val" id="m-uptime">00:00:00</span>
      </div>
    </div>

    <div class="metrics-section">
      <div class="metrics-title">Engine Status</div>
      <div class="metric-row">
        <span class="metric-key">CLAMAV</span>
        <span class="metric-val" style="color: var(--green); font-size: 9px;">DAEMON OK</span>
      </div>
      <div class="metric-row">
        <span class="metric-key">SSE STREAM</span>
        <span class="metric-val" id="m-sse" style="color: var(--green); font-size: 9px;">CONNECTED</span>
      </div>
      <div class="metric-row">
        <span class="metric-key">LAST_EVENT</span>
        <span class="metric-val" id="m-last">—</span>
      </div>
    </div>

    <div id="alert-zone">
      <div id="alert-default" class="alert-block info" style="font-size:9px; line-height:1.7; letter-spacing:1px;">
        AEGIS ONLINE<br>
        ENGINES READY<br>
        AWAITING DEVICE
      </div>
    </div>
  </aside>

</div><!-- #app -->

<!-- FORMAT CONFIRMATION MODAL -->
<div id="modal-overlay">
  <div class="modal-box">
    <div class="modal-icon">&#9888;&#65039;</div>
    <div class="modal-title">DESTRUCTIVE ACTION</div>
    <div class="modal-sub">IRREVERSIBLE OPERATION — CONFIRM TO PROCEED</div>
    <div class="modal-body">
      This operation will permanently erase ALL data on the USB device in Port 1 (Type-A) and reformat it as FAT32 with label "CLEAN_USB".<br><br>
      <strong style="color: var(--red);">ALL DATA WILL BE LOST. THIS CANNOT BE UNDONE.</strong>
    </div>
    <div class="modal-actions">
      <button class="modal-btn modal-btn-cancel" onclick="closeFormatModal()">ABORT</button>
      <button class="modal-btn modal-btn-confirm" onclick="executeFormat()">CONFIRM FORMAT</button>
    </div>
  </div>
</div>

<script>
  // ── State ──────────────────────────────────────────────
  let currentStatus = "WAITING";
  let sessionScans = 0;
  let sessionThreats = 0;
  let sessionStart = Date.now();
  let watchdogTimer = null;
  let heartbeatActive = false;
  let totalFiles = 0;
  const SESSION_ID = Math.random().toString(36).substr(2,6).toUpperCase();

  document.getElementById('m-session').textContent = SESSION_ID;

  // ── Clock & Uptime ─────────────────────────────────────
  function padZ(n) { return String(n).padStart(2,'0'); }

  function updateClock() {
    const now = new Date();
    document.getElementById('clock').textContent =
      `${padZ(now.getHours())}:${padZ(now.getMinutes())}:${padZ(now.getSeconds())}`;

    const up = Math.floor((Date.now() - sessionStart) / 1000);
    const h = Math.floor(up / 3600);
    const m = Math.floor((up % 3600) / 60);
    const s = up % 60;
    document.getElementById('m-uptime').textContent = `${padZ(h)}:${padZ(m)}:${padZ(s)}`;
  }

  setInterval(updateClock, 1000);
  updateClock();

  // ── Terminal ────────────────────────────────────────────
  const terminal = document.getElementById('terminal');
  const termIdle = document.getElementById('term-idle');
  let lineCount = 0;

  function appendLine(html) {
    if (termIdle) termIdle.remove();
    const div = document.createElement('div');
    div.className = 'line line-new';
    div.innerHTML = html.replace(/<br\s*\/?>/gi, '');
    terminal.appendChild(div);
    lineCount++;
    if (lineCount > 600) terminal.removeChild(terminal.firstChild);
    terminal.scrollTop = terminal.scrollHeight;
    document.getElementById('m-last').textContent =
      new Date().toLocaleTimeString('en-GB', {hour12:false});
  }

  // ── Status ──────────────────────────────────────────────
  function applyStatus(s) {
    if (s === currentStatus) return;
    currentStatus = s;

    const badge = document.getElementById('status-badge');
    badge.className = 'status-' + s;

    const labels = {
      WAITING:    'SYSTEM READY — INSERT USB DEVICE',
      SCANNING:   'ANALYSIS IN PROGRESS',
      CLEAN:      'THREAT ANALYSIS COMPLETE — NO THREATS',
      INFECTED:   'THREAT ANALYSIS COMPLETE — THREATS FOUND',
      FORMATTING: 'FORMAT IN PROGRESS — DO NOT REMOVE DEVICE',
      ERROR:      'ENGINE ERROR — CHECK DEVICE'
    };

    badge.textContent = s;
    document.getElementById('status-detail').textContent = labels[s] || s;
    document.getElementById('transfer-btn').disabled = (s !== 'CLEAN');
    document.body.className = s === 'INFECTED' ? 'infected' : '';

    if (s === 'WAITING') {
      terminal.innerHTML = '<div class="term-idle">[ AWAITING SCAN DATA ]</div>';
      lineCount = 0;
      hideProgress();
      setHeartbeat(false);
      setAlert('default');
    } else if (s === 'SCANNING') {
      terminal.innerHTML = '';
      lineCount = 0;
      document.getElementById('alert-zone').innerHTML = `
        <div class="alert-block info">SCAN INITIATED<br>ENGINE LOADING...<br>STREAMING LIVE DATA</div>`;
    } else if (s === 'CLEAN') {
      sessionScans++;
      document.getElementById('m-scans').textContent = sessionScans;
      setHeartbeat(false);
      clearWatchdog();
      updateHistory();
      setTimeout(hideProgress, 2000);
      document.getElementById('alert-zone').innerHTML = `
        <div class="alert-block ok">SCAN COMPLETE<br>NO THREATS FOUND<br>DRIVE IS CLEAN</div>`;
    } else if (s === 'INFECTED') {
      sessionScans++;
      sessionThreats++;
      document.getElementById('m-scans').textContent = sessionScans;
      document.getElementById('m-threats').textContent = sessionThreats;
      document.getElementById('m-threats').style.color = 'var(--red)';
      setHeartbeat(false);
      clearWatchdog();
      updateHistory();
      setTimeout(hideProgress, 2000);
      document.getElementById('alert-zone').innerHTML = `
        <div class="alert-block threat">⚠ THREATS DETECTED<br>DO NOT TRANSFER<br>REVIEW TERMINAL LOG</div>`;
    }
  }

  // ── Progress ────────────────────────────────────────────
  function showProgress() {
    document.getElementById('progress-section').classList.add('visible');
  }

  function hideProgress() {
    document.getElementById('progress-section').classList.remove('visible');
    document.getElementById('progress-fill').style.width = '0%';
    document.getElementById('progress-label').textContent = '0%';
  }

  function setProgress(pct) {
    const fill = document.getElementById('progress-fill');
    fill.style.width = pct + '%';
    document.getElementById('progress-label').textContent = `FILE ANALYSIS: ${pct}%`;
  }

  // ── Heartbeat ───────────────────────────────────────────
  function setHeartbeat(active) {
    const ring = document.getElementById('heartbeat-ring');
    heartbeatActive = active;
    ring.classList.toggle('active', active);
    if (active) resetWatchdog();
  }

  // ── Watchdog ─────────────────────────────────────────────
  function resetWatchdog() {
    clearWatchdog();
    if (['WAITING','CLEAN','INFECTED'].includes(currentStatus)) return;
    watchdogTimer = setTimeout(() => {
      document.getElementById('status-detail').textContent =
        '⚠ ENGINE PROCESSING LARGE FILES — PLEASE WAIT';
    }, 45000);
  }

  function clearWatchdog() {
    if (watchdogTimer) clearTimeout(watchdogTimer);
    watchdogTimer = null;
  }

  // ── SSE Stream ──────────────────────────────────────────
  const source = new EventSource('/stream');

  source.onopen = () => {
    document.getElementById('m-sse').textContent = 'CONNECTED';
    document.getElementById('m-sse').style.color = 'var(--green)';
  };

  source.onerror = () => {
    document.getElementById('m-sse').textContent = 'RECONNECTING';
    document.getElementById('m-sse').style.color = 'var(--amber)';
  };

  source.onmessage = function(e) {
    const data = e.data;

    if (data.startsWith('STATUS:')) {
      const s = data.split(':')[1].trim();
      applyStatus(s);
      return;
    }

    if (data.startsWith('FEEDBACK:TOTAL:')) {
      totalFiles = parseInt(data.split(':')[2]) || 0;
      showProgress();
      document.getElementById('status-detail').textContent =
        `ENGINE LOADED — ANALYZING ${totalFiles} FILES`;
      return;
    }

    if (data.startsWith('FEEDBACK:CURRENT:')) {
      const pct = parseInt(data.split(':')[2]) || 0;
      setProgress(pct);
      document.getElementById('status-detail').textContent =
        `FILE ANALYSIS: ${pct}% COMPLETE`;
      return;
    }

    if (data.startsWith('FEEDBACK:HEARTBEAT:')) {
      setHeartbeat(true);
      resetWatchdog();
      if (!document.getElementById('status-detail').textContent.includes('%')) {
        document.getElementById('status-detail').textContent = 'CLAMAV ENGINE ACTIVE — DEEP SCAN IN PROGRESS';
      }
      return;
    }

    // Raw log line
    appendLine(data);
  };

  // ── Hardware Polling ────────────────────────────────────
  function checkHardware() {
    fetch('/ports').then(r => r.json()).then(d => {
      updatePort('port-a', 'label-a', d.type_a);
      updatePort('port-c', 'label-c', d.type_c);
    }).catch(() => {});
  }

  function updatePort(cardId, labelId, connected) {
    const card = document.getElementById(cardId);
    const label = document.getElementById(labelId);
    card.classList.toggle('connected', connected);
    label.textContent = connected ? 'DEVICE DETECTED' : 'NO DEVICE';
  }

  setInterval(checkHardware, 1200);
  checkHardware();

  // ── History ─────────────────────────────────────────────
  function updateHistory() {
    fetch('/history').then(r => r.json()).then(items => {
      document.getElementById('hist-count').textContent = items.length;
      if (!items.length) {
        document.getElementById('history-list').innerHTML =
          '<div style="padding:16px; text-align:center; color:var(--text-ghost); font-family:var(--font-mono); font-size:9px; letter-spacing:2px;">NO RECORDS</div>';
        return;
      }
      document.getElementById('history-list').innerHTML = items.map(item => {
        const raw = item.file.replace('scan_','').replace('.log','');
        const yr   = raw.substr(0,4);
        const mo   = raw.substr(4,2);
        const dy   = raw.substr(6,2);
        const hr   = raw.substr(9,2);
        const mn   = raw.substr(11,2);
        const sc   = raw.substr(13,2);
        const label = `${yr}-${mo}-${dy} ${hr}:${mn}:${sc}`;
        const tag = item.status === 'INFECTED'
          ? `<span class="h-tag h-tag-infected">INFECTED</span>`
          : `<span class="h-tag h-tag-clean">CLEAN</span>`;
        return `<div class="h-item" onclick="loadHistoryLog('${item.file}')">
          <span class="h-item-date">${label}</span>${tag}</div>`;
      }).join('');
    }).catch(() => {});
  }

  function loadHistoryLog(filename) {
    fetch('/get_history_log/' + filename).then(r => r.text()).then(content => {
      terminal.innerHTML = '';
      lineCount = 0;
      content.split('\n').forEach(line => {
        if (line.trim()) appendLine(line);
      });
    });
  }

  updateHistory();
  setInterval(updateHistory, 10000);

  // ── Operation Overlay ───────────────────────────────────
  // Shared by Format and Transfer. Colour-coded: amber=format, green=transfer.
  function showOpOverlay(cfg) {
    // cfg: { title, subtitle, accent, glow, svgPath }
    const overlay = document.getElementById('op-overlay');
    const box     = document.getElementById('op-box');
    box.style.setProperty('--op-accent', cfg.accent);
    box.style.setProperty('--op-glow',   cfg.glow);
    document.getElementById('op-title').textContent    = cfg.title;
    document.getElementById('op-subtitle').textContent = cfg.subtitle;
    document.getElementById('op-svg').innerHTML        = cfg.svgPath;
    document.getElementById('op-svg').setAttribute('stroke', cfg.accent);
    document.getElementById('op-status-line').textContent = 'Initializing...';
    document.getElementById('op-status-line').style.color = '';
    document.getElementById('op-result').style.display  = 'none';
    document.getElementById('op-result').className      = 'op-result';
    document.getElementById('op-result').textContent    = '';
    document.getElementById('op-dismiss').style.display = 'none';
    document.getElementById('op-bar').style.animationPlayState = 'running';
    overlay.classList.add('open');
  }

  function finishOpOverlay(success, message) {
    document.getElementById('op-bar').style.animationPlayState = 'paused';
    const res = document.getElementById('op-result');
    res.className = 'op-result ' + (success ? 'ok' : 'fail');
    res.textContent = message;
    res.style.display = 'block';
    document.getElementById('op-status-line').textContent = success ? 'OPERATION COMPLETE' : 'OPERATION FAILED';
    document.getElementById('op-status-line').style.color = success ? 'var(--green)' : 'var(--red)';
    document.getElementById('op-dismiss').style.display = 'block';
  }

  function dismissOpOverlay() {
    document.getElementById('op-overlay').classList.remove('open');
  }

  // ── Transfer ────────────────────────────────────────────
  function runTransfer() {
    const btn = document.getElementById('transfer-btn');
    btn.innerHTML = '<span>&#8635;</span> TRANSFERRING...';
    btn.disabled = true;

    showOpOverlay({
      title:   'SECURE TRANSFER',
      subtitle: 'COPYING FILES TO CLEAN DRIVE — DO NOT REMOVE DEVICES',
      accent:  'var(--green)',
      glow:    'rgba(0,255,136,0.3)',
      svgPath: '<polyline points="2,9 7,14 16,4" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
    });
    document.getElementById('op-status-line').textContent = 'Mounting source drive...';

    fetch('/transfer').then(r => r.json()).then(d => {
      const ok = d.message && d.message.includes('SUCCESS');
      finishOpOverlay(ok, d.message ? d.message.trim().substring(0, 200) : 'Unknown result');
      btn.innerHTML = '<span>&#9875;</span> TRANSFER FILES';
      btn.disabled  = (currentStatus !== 'CLEAN');
    }).catch(err => {
      finishOpOverlay(false, 'Network error — check Flask server.');
      btn.innerHTML = '<span>&#9875;</span> TRANSFER FILES';
      btn.disabled  = (currentStatus !== 'CLEAN');
    });
  }

  // ── Format ──────────────────────────────────────────────
  function openFormatModal() {
    document.getElementById('modal-overlay').classList.add('open');
  }

  function closeFormatModal() {
    document.getElementById('modal-overlay').classList.remove('open');
  }

  function executeFormat() {
    closeFormatModal();
    const btn = document.getElementById('format-btn');
    btn.innerHTML = '<span>&#8635;</span> FORMATTING...';
    btn.disabled  = true;

    showOpOverlay({
      title:   'DRIVE FORMAT',
      subtitle: 'ERASING AND FORMATTING FAT32 — DO NOT REMOVE DEVICE',
      accent:  'var(--amber)',
      glow:    'rgba(255,170,0,0.3)',
      svgPath: '<path d="M9 2v5M9 11v5M2 9h5M11 9h5" stroke-width="1.8" stroke-linecap="round"/><circle cx="9" cy="9" r="2.5" stroke-width="1.5"/>'
    });
    document.getElementById('op-status-line').textContent = 'Writing FORMATTING sentinel...';

    fetch('/format', {method:'POST'}).then(r => r.json()).then(d => {
      const ok = d.status === 'success';
      finishOpOverlay(ok, d.message ? d.message.trim().substring(0, 200) : 'Unknown result');
      btn.innerHTML = '<span>&#9888;</span> FORMAT DRIVE';
      btn.disabled  = false;
    }).catch(err => {
      finishOpOverlay(false, 'Network error — check Flask server.');
      btn.innerHTML = '<span>&#9888;</span> FORMAT DRIVE';
      btn.disabled  = false;
    });
  }

  // ── Alert Helper ────────────────────────────────────────
  function setAlert(type) {
    if (type === 'default') {
      document.getElementById('alert-zone').innerHTML = `
        <div id="alert-default" class="alert-block info" style="font-size:9px;line-height:1.7;letter-spacing:1px;">
          AEGIS ONLINE<br>ENGINES READY<br>AWAITING DEVICE
        </div>`;
    }
  }

  // Close modal on overlay click
  document.getElementById('modal-overlay').addEventListener('click', function(e) {
    if (e.target === this) closeFormatModal();
  });
</script>
</body>
</html>"""


@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE)


@app.route('/ports')
def get_ports():
    return jsonify({
        "type_a": os.path.exists(f"/dev/disk/by-path/{PORT_A_ID}"),
        "type_c": os.path.exists(f"/dev/disk/by-path/{PORT_C_ID}")
    })


@app.route('/history')
def get_history():
    history = []
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    files = sorted(glob.glob(os.path.join(ARCHIVE_DIR, "*.log")), reverse=True)
    for f in files[:20]:
        name = os.path.basename(f)
        status = "CLEAN"
        try:
            with open(f, 'r', errors='replace') as log_content:
                text = log_content.read()
                if "THREATS IDENTIFIED" in text or "INFECTED" in text:
                    status = "INFECTED"
        except Exception:
            pass
        history.append({"file": name, "status": status})
    return jsonify(history)


@app.route('/get_history_log/<filename>')
def get_history_log(filename):
    safe_name = os.path.basename(filename)
    return send_from_directory(ARCHIVE_DIR, safe_name)


@app.route('/transfer')
def transfer():
    try:
        res = subprocess.check_output(
            ["sudo", "/usr/local/bin/usbcopy.sh"],
            stderr=subprocess.STDOUT
        )
        return jsonify({"message": res.decode(errors='replace')})
    except subprocess.CalledProcessError as e:
        return jsonify({"message": f"Transfer Error: {e.output.decode(errors='replace')}"})


@app.route('/format', methods=['POST'])
def format_drive():
    try:
        res = subprocess.check_output(
            ["sudo", "/usr/local/bin/usbformat.sh"],
            stderr=subprocess.STDOUT
        )
        output = res.decode(errors='replace')
        if "SUCCESS" in output:
            return jsonify({"status": "success", "message": output.strip()})
        else:
            return jsonify({"status": "error", "message": output.strip()})
    except subprocess.CalledProcessError as e:
        output = e.output.decode(errors='replace')
        return jsonify({"status": "error", "message": output.strip()})


@app.route('/stream')
def stream():
    def generate():
        last_pos = 0
        last_status = None
        log_path = os.path.join(BASE_DIR, "usbscan.log")
        result_path = os.path.join(BASE_DIR, "result.txt")

        while True:
            # ── Determine current status ──────────────────
            current_status = "WAITING"

            if os.path.exists(result_path):
                try:
                    with open(result_path, "r") as rf:
                        val = rf.read().strip()
                        if val:
                            current_status = val
                    # While FORMATTING sentinel is active, hold that state and
                    # skip log streaming entirely. This prevents udev from
                    # re-triggering usbscan.sh's log writes from being mistaken
                    # for a new scan starting.
                    if current_status == "FORMATTING":
                        if current_status != last_status:
                            yield f"data: STATUS:FORMATTING\n\n"
                            last_status = current_status
                        time.sleep(0.5)
                        continue
                except Exception:
                    pass
            elif os.path.exists(log_path):
                try:
                    if (time.time() - os.path.getmtime(log_path)) < 5:
                        current_status = "SCANNING"
                except Exception:
                    pass

            if current_status != last_status:
                yield f"data: STATUS:{current_status}\n\n"
                last_status = current_status

            # ── Stream new log lines via seek ─────────────
            if os.path.exists(log_path):
                try:
                    current_size = os.path.getsize(log_path)

                    # File was truncated (new scan started)
                    if current_size < last_pos:
                        last_pos = 0

                    if current_size > last_pos:
                        with open(log_path, "r", errors='replace') as lf:
                            lf.seek(last_pos)
                            lines = lf.readlines()
                            last_pos = lf.tell()
                            for line in lines:
                                stripped = line.strip()
                                if stripped:
                                    yield f"data: {stripped}\n\n"
                except Exception:
                    pass

            time.sleep(0.1)

    return Response(
        generate(),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no'
        }
    )


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, threaded=True)
