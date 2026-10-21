{% set user = 'mlops' %}
{% set home = '/home/' ~ user %}
include:
  - mlops.backend
  - mlops.huggingface
{% set dgemma_dir = home ~ '/models/DiffusionGemma-26B-A4B-GGUF' %}

# ==============================================================================
# 1. Base Packages & System Dependencies (Fedora 44)
# ==============================================================================
halo395_base_packages:
  pkg.installed:
    - names:
      - podman
      - toolbox
      - python3-pip
      - git
      - wget2-wget
      - jq
      - tuned
      - firewalld
      - pciutils
      - vulkan-tools

# ==============================================================================
# 2. User Account, Groups, and Rootless Podman SubUID/SubGID Mappings
# ==============================================================================
halo395_user_account:
  user.present:
    - name: {{ user }}
    - home: {{ home }}
    - groups:
      - video
      - render
      - wheel
    - remove_groups: False
    - require:
      - pkg: halo395_base_packages

halo395_subuid_mapping:
  file.append:
    - name: /etc/subuid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subuid
    - require:
      - user: halo395_user_account

halo395_subgid_mapping:
  file.append:
    - name: /etc/subgid
    - text: "{{ user }}:100000:65536"
    - unless: grep -q "^{{ user }}:" /etc/subgid
    - require:
      - user: halo395_user_account

# ==============================================================================
# 3. Home Directory Permissions & Podman Migration
# ==============================================================================
halo395_home_dir_permissions:
  file.directory:
    - name: {{ home }}
    - user: {{ user }}
    - group: {{ user }}
    - dir_mode: '0755'
    - require:
      - user: halo395_user_account

halo395_local_share_dir:
  file.directory:
    - name: {{ home }}/.local/share
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - file: halo395_home_dir_permissions

halo395_podman_migrate:
  cmd.run:
    - name: podman system migrate
    - runas: {{ user }}
    - onchanges:
      - file: halo395_subuid_mapping
      - file: halo395_subgid_mapping
      - file: halo395_home_dir_permissions

# ==============================================================================
# 4. PAM Locked Memory & 124GB Unified GTT Pool (amdgpu)
# ==============================================================================
halo395_memlock_limits:
  file.managed:
    - name: /etc/security/limits.d/99-amdgpu-memlock.conf
    - mode: '0644'
    - contents: |
        * soft memlock unlimited
        * hard memlock unlimited

halo395_amdgpu_gtt_modprobe:
  file.managed:
    - name: /etc/modprobe.d/amdgpu-gtt.conf
    - mode: '0644'
    - contents: |
        # Allocate up to 124 GB (126976 MiB) of 128 GB LPDDR5X to GPU GTT pool
        options amdgpu gttsize=126976 pages_limit=32505856

# ==============================================================================
# 5. Disable Sleep Targets & Lock Strix Halo Performance Clocks
# ==============================================================================
{% for target in ['sleep', 'suspend', 'hibernate', 'hybrid-sleep', 'suspend-then-hibernate'] %}
mask_halo395_{{ target }}_target:
  service.masked:
    - name: {{ target }}.target
{% endfor %}

halo395_tuned_service:
  service.running:
    - name: tuned
    - enable: True
    - require:
      - pkg: halo395_base_packages

halo395_tuned_profile:
  cmd.run:
    - name: tuned-adm profile throughput-performance
    - unless: tuned-adm active | grep -q "throughput-performance"
    - require:
      - service: halo395_tuned_service

halo395_amdgpu_high_dpm_udev:
  file.managed:
    - name: /etc/udev/rules.d/30-amdgpu-high-dpm.rules
    - mode: '0644'
    - contents: |
        KERNEL=="card[0-9]", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="high"

halo395_apply_amdgpu_dpm_now:
  cmd.run:
    - name: bash -c 'echo high > /sys/class/drm/card*/device/power_dpm_force_performance_level'
    - unless: grep -q "^high$" /sys/class/drm/card*/device/power_dpm_force_performance_level
    - onlyif: ls /sys/class/drm/card*/device/power_dpm_force_performance_level

# ==============================================================================
# 6. Ensure Firewalld Is Running (inference-firewall Manages Port 8080 Rules)
# ==============================================================================
halo395_firewalld_service:
  service.running:
    - name: firewalld
    - enable: True
    - require:
      - pkg: halo395_base_packages

halo395_firewall_port_8080:
  cmd.run:
    - name: firewall-cmd --permanent --remove-port=8080/tcp; firewall-cmd --remove-port=8080/tcp
    - onlyif: firewall-cmd --query-port=8080/tcp || firewall-cmd --permanent --query-port=8080/tcp
    - require:
      - service: halo395_firewalld_service

# ==============================================================================
# 7. Install Hugging Face CLI (with hf_xet) & Ensure PATH in .bashrc
# ==============================================================================
halo395_install_hf_cli:
  cmd.run:
    - name: pip3 install --user -U "huggingface_hub[cli,hf_xet]"
    - runas: {{ user }}
    - creates: {{ home }}/.local/bin/hf
    - require:
      - pkg: halo395_base_packages
      - user: halo395_user_account

halo395_user_bashrc_path:
  file.append:
    - name: {{ home }}/.bashrc
    - text: 'export PATH="$HOME/.local/bin:$PATH"'
    - unless: grep -q '\.local/bin' {{ home }}/.bashrc
    - require:
      - user: halo395_user_account

# ==============================================================================
# 8. Enable Linger, Create Vulkan RADV Toolbx & Compile llama.cpp PR #24423
# ==============================================================================
halo395_enable_linger:
  cmd.run:
    - name: loginctl enable-linger {{ user }}
    - creates: /var/lib/systemd/linger/{{ user }}
    - require:
      - user: halo395_user_account

halo395_create_vulkan_toolbox:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        toolbox --assumeyes create llama-vulkan-radv \
          --image docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-radv
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman container exists llama-vulkan-radv
    - require:
      - cmd: halo395_enable_linger
      - file: halo395_local_share_dir
      - file: halo395_memlock_limits
      - cmd: halo395_podman_migrate

halo395_build_llama_pr24423_diffusion:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user stop strix-llama-router.service || true
        podman start llama-vulkan-radv
        podman exec --user 0 llama-vulkan-radv bash -e -c '
          dnf reinstall -y binutils
          dnf install -y lld mold git cmake gcc gcc-c++ ninja-build \
            vulkan-headers vulkan-loader-devel glslc libcurl-devel \
            python3 python3-pip python3-sentencepiece python3-protobuf
          if [ ! -e /usr/bin/ld ]; then
            ln -sf /usr/bin/ld.bfd /usr/bin/ld || ln -sf /usr/bin/ld.lld /usr/bin/ld
          fi
          rm -f /usr/local/lib64/libllama* /usr/local/lib64/libggml* /usr/local/lib64/libmtmd*
          rm -f /usr/lib64/libllama* /usr/lib64/libggml* /usr/lib64/libmtmd*
          ldconfig
          if [ ! -d /opt/llama-pr24423/.git ]; then
            rm -rf /opt/llama-pr24423
            git clone https://github.com/ggml-org/llama.cpp.git /opt/llama-pr24423
          fi
          cd /opt/llama-pr24423
          git fetch origin pull/24423/head
          git checkout -f FETCH_HEAD
          python3 - << "PY"
        from pathlib import Path
        p = Path("/opt/llama-pr24423/examples/diffusion-gemma-server/diffusion-gemma-visual-server.cpp")
        code = p.read_text()
        target = "inputs.add_generation_prompt = true;"
        replacement = """inputs.add_generation_prompt = true;
                    if (req.contains("enable_thinking")) {
                        inputs.enable_thinking = req.at("enable_thinking").get<bool>();
                    }"""
        if "req.contains(\"enable_thinking\")" not in code:
            code = code.replace(target, replacement, 1)
        # Only enforce the O(N^2) fp32 scores buffer limit when Flash Attention is OFF (!fa_on)
        code = code.replace("if (budget) {", "if (budget && !fa_on) {")
        p.write_text(code)
        PY
          if [ ! -f /opt/llama-pr24423/build/build.ninja ]; then
            cmake -B /opt/llama-pr24423/build -S /opt/llama-pr24423 -G Ninja \
              -DCMAKE_BUILD_TYPE=Release \
              -DBUILD_SHARED_LIBS=OFF \
              -DLLAMA_BUILD_EXAMPLES=ON \
              -DGGML_VULKAN=ON \
              -DGGML_NATIVE=ON
          fi
          cmake --build /opt/llama-pr24423/build --config Release -j $(nproc) \
            --target llama-diffusion-cli llama-diffusion-gemma-server llama-diffusion-gemma-visual-server llama-quantize
          cp -af /opt/llama-pr24423/build/bin/llama-diffusion* /usr/local/bin/
          cp -af /opt/llama-pr24423/build/bin/llama-diffusion* /usr/bin/
          cp -af /opt/llama-pr24423/build/bin/llama-quantize /usr/local/bin/ || true
          touch /etc/llama-built-pr24423-visual-server-64k
        '
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman start llama-vulkan-radv >/dev/null 2>&1
        podman exec llama-vulkan-radv test -f /etc/llama-built-pr24423-visual-server-64k && \
        podman exec llama-vulkan-radv test -x /usr/local/bin/llama-diffusion-gemma-visual-server
    - timeout: 1800
    - require:
      - cmd: halo395_create_vulkan_toolbox

# ==============================================================================
# 9. Download & Convert google/diffusiongemma-26b-A4B-it to Q4_K_M GGUF
# ==============================================================================
halo395_download_diffusiongemma_26b_a4b:
  cmd.run:
    - name: |
        mkdir -p {{ dgemma_dir }}
        HF_XET_HIGH_PERFORMANCE=1 {{ home }}/.local/bin/hf download google/diffusiongemma-26b-A4B-it \
          --local-dir {{ dgemma_dir }}/hf-source
        if [ ! -x {{ home }}/.venv-gguf/bin/python ]; then
          python3 -m venv {{ home }}/.venv-gguf
        fi
        {{ home }}/.venv-gguf/bin/pip install -q --upgrade pip
        {{ home }}/.venv-gguf/bin/pip install -q \
          --extra-index-url https://download.pytorch.org/whl/cpu \
          torch numpy safetensors sentencepiece protobuf transformers
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        podman start llama-vulkan-radv
        podman cp llama-vulkan-radv:/opt/llama-pr24423/convert_hf_to_gguf.py {{ dgemma_dir }}/convert_hf_to_gguf.py
        podman cp llama-vulkan-radv:/opt/llama-pr24423/gguf-py {{ dgemma_dir }}/gguf-py
        {{ home }}/.venv-gguf/bin/pip install -q -e {{ dgemma_dir }}/gguf-py
        if [ ! -s {{ dgemma_dir }}/diffusiongemma-26B-A4B-it-f16.gguf ]; then
          {{ home }}/.venv-gguf/bin/python {{ dgemma_dir }}/convert_hf_to_gguf.py \
            {{ dgemma_dir }}/hf-source \
            --outfile {{ dgemma_dir }}/diffusiongemma-26B-A4B-it-f16.gguf \
            --outtype f16
        fi
        podman exec llama-vulkan-radv /usr/local/bin/llama-quantize \
          {{ dgemma_dir }}/diffusiongemma-26B-A4B-it-f16.gguf \
          {{ dgemma_dir }}/diffusiongemma-26B-A4B-it-Q4_K_M.gguf Q4_K_M
        rm -f {{ dgemma_dir }}/diffusiongemma-26B-A4B-it-f16.gguf
    - runas: {{ user }}
    - creates: {{ dgemma_dir }}/diffusiongemma-26B-A4B-it-Q4_K_M.gguf
    - timeout: 7200
    - require:
      - cmd: halo395_install_hf_cli
      - cmd: halo395_build_llama_pr24423_diffusion

# ==============================================================================
# 10. Manage OpenAI HTTP Proxy for llama-diffusion-gemma-visual-server (64K Context)
# ==============================================================================
halo395_diffusion_openai_proxy:
  file.managed:
    - name: {{ home }}/.local/bin/diffusion-openai-proxy.py
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0755'
    - makedirs: True
    - contents: |
        #!/usr/bin/env python3
        import json
        import math
        import os
        import re
        import subprocess
        import tempfile
        import threading
        import time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        MODEL_ID = os.environ.get("DG_MODEL_ID", "DiffusionGemma-26B-A4B")
        MODEL_PATH = os.environ.get(
            "DG_MODEL_PATH",
            "{{ dgemma_dir }}/diffusiongemma-26B-A4B-it-Q4_K_M.gguf",
        )
        KEY_FILE = os.environ.get("DG_API_KEY_FILE", "{{ home }}/.config/llama/backend-key")
        PORT = int(os.environ.get("DG_PORT", "8080"))
        CANVAS_LEN = 256


        def load_api_key():
            if os.path.exists(KEY_FILE):
                with open(KEY_FILE, "r", encoding="utf-8") as f:
                    return f.read().strip()
            return ""


        API_KEY = load_api_key()


        class DiffusionGemmaWorker:
            def __init__(self):
                self.lock = threading.Lock()
                self.proc = None
                self.n_vocab = 0
                self.max_tok = 65536
                self.created = int(time.time())
                self.start_worker()

            def start_worker(self):
                env = os.environ.copy()
                env.setdefault("NGL", "999")
                env.setdefault("FA", "1")
                env.setdefault("MAXTOK", "65536")
                cmd = ["/usr/local/bin/llama-diffusion-gemma-visual-server", MODEL_PATH]
                print(f"[proxy] Starting {' '.join(cmd)} (NGL={env['NGL']}, FA={env['FA']}, MAXTOK={env['MAXTOK']})...", flush=True)
                self.proc = subprocess.Popen(
                    cmd,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=None,
                    text=True,
                    bufsize=1,
                    env=env,
                )
                while True:
                    line = self.proc.stdout.readline()
                    if not line:
                        raise RuntimeError("llama-diffusion-gemma-visual-server exited before READY")
                    line = line.strip()
                    if line.startswith("READY"):
                        parts = line.split()
                        if len(parts) >= 2:
                            self.n_vocab = int(parts[1])
                        if len(parts) >= 3:
                            self.max_tok = int(parts[2])
                        print(f"[proxy] Worker READY: n_vocab={self.n_vocab}, max_tok={self.max_tok}", flush=True)
                        break

            def ensure_alive(self):
                if self.proc is None or self.proc.poll() is not None:
                    print("[proxy] Worker process died, restarting...", flush=True)
                    self.start_worker()


        WORKER = None


        def split_reasoning_and_content(raw_text: str):
            cleaned = re.sub(r"^<\|channel>thought\s*<channel\|>\s*", "", raw_text)
            m = re.search(r"<\|channel>thought\s*(.*?)<channel\|>(.*)", cleaned, flags=re.DOTALL)
            if m:
                return m.group(1).strip(), m.group(2).lstrip()
            if cleaned.startswith("<|channel>thought"):
                thought = re.sub(r"^<\|channel>thought\s*", "", cleaned, count=1)
                return thought.strip(), ""
            return "", cleaned


        class OpenAIHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def check_auth(self):
                if not API_KEY:
                    return True
                auth = self.headers.get("Authorization", "")
                if auth == f"Bearer {API_KEY}":
                    return True
                self.send_json(401, {"error": {"message": "Invalid API Key", "type": "authentication_error", "code": 401}})
                return False

            def send_json(self, code: int, payload: dict):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                if self.path in ("/health", "/v1/health"):
                    self.send_json(200, {"status": "ok"})
                    return
                if not self.check_auth():
                    return
                if self.path.startswith("/v1/models"):
                    self.send_json(
                        200,
                        {
                            "object": "list",
                            "data": [
                                {
                                    "id": MODEL_ID,
                                    "object": "model",
                                    "created": WORKER.created,
                                    "owned_by": "llamacpp-diffusion",
                                    "status": {"value": "loaded", "max_tokens": WORKER.max_tok},
                                }
                            ],
                        },
                    )
                    return
                self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error"}})

            def do_POST(self):
                if not self.check_auth():
                    return
                if not self.path.startswith("/v1/chat/completions"):
                    self.send_json(404, {"error": {"message": "Not found", "type": "invalid_request_error"}})
                    return

                length = int(self.headers.get("Content-Length", "0"))
                raw_body = self.rfile.read(length).decode("utf-8")
                try:
                    req = json.loads(raw_body)
                except Exception as e:
                    self.send_json(400, {"error": {"message": f"Invalid JSON: {e}", "type": "invalid_request_error"}})
                    return

                messages = req.get("messages", [])
                stream = bool(req.get("stream", False))
                seed = int(req.get("seed", 0) or 0)
                max_tokens = int(req.get("max_tokens") or req.get("max_completion_tokens") or 2048)
                n_blocks = max(1, min(64, math.ceil(max_tokens / CANVAS_LEN)))
                if "n_blocks" in req:
                    n_blocks = int(req["n_blocks"])

                enable_thinking = True
                ct_kwargs = req.get("chat_template_kwargs") or {}
                if "enable_thinking" in ct_kwargs:
                    enable_thinking = bool(ct_kwargs["enable_thinking"])
                elif "enable_thinking" in req:
                    enable_thinking = bool(req["enable_thinking"])
                if req.get("reasoning_effort") == "none" or ct_kwargs.get("reasoning_effort") == "none":
                    enable_thinking = False

                worker_req = {
                    "seed": seed,
                    "n_blocks": n_blocks,
                    "enable_thinking": enable_thinking,
                    "messages": messages,
                }
                if "tools" in req and req["tools"]:
                    worker_req["tools"] = req["tools"]

                with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
                    json.dump(worker_req, tf)
                    req_path = tf.name

                created_ts = int(time.time())
                req_id = f"chatcmpl-dg-{int(time.time() * 1000)}"

                try:
                    with WORKER.lock:
                        WORKER.ensure_alive()
                        if stream:
                            self.send_response(200)
                            self.send_header("Content-Type", "text/event-stream")
                            self.send_header("Cache-Control", "no-cache")
                            self.send_header("Connection", "close")
                            self.end_headers()

                        WORKER.proc.stdin.write(req_path + "\n")
                        WORKER.proc.stdin.flush()

                        committed_text = ""
                        prev_r_len = 0
                        prev_c_len = 0
                        first_step_sent = False
                        stats = {}
                        err_msg = None

                        while True:
                            line = WORKER.proc.stdout.readline()
                            if not line:
                                err_msg = "Worker EOF during generation"
                                break
                            line = line.rstrip("\r\n")
                            if line == "DONE":
                                break
                            if line.startswith("ERR "):
                                err_msg = line[4:]
                                break
                            if line.startswith("F ") and stream and not first_step_sent:
                                first_step_sent = True
                                chunk = {
                                    "id": req_id,
                                    "object": "chat.completion.chunk",
                                    "created": created_ts,
                                    "model": MODEL_ID,
                                    "choices": [
                                        {
                                            "index": 0,
                                            "delta": {"role": "assistant", "content": ""},
                                            "finish_reason": None,
                                        }
                                    ],
                                }
                                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode("utf-8"))
                                self.wfile.flush()
                            elif line.startswith("C "):
                                parts = line.split(" ", 2)
                                if len(parts) == 3:
                                    committed_text = json.loads(parts[2])
                                    if stream:
                                        r_txt, c_txt = split_reasoning_and_content(committed_text)
                                        r_delta = r_txt[prev_r_len:]
                                        c_delta = c_txt[prev_c_len:]
                                        prev_r_len = len(r_txt)
                                        prev_c_len = len(c_txt)
                                        delta_obj = {}
                                        if r_delta:
                                            delta_obj["reasoning_content"] = r_delta
                                        if c_delta:
                                            delta_obj["content"] = c_delta
                                        if delta_obj:
                                            chunk = {
                                                "id": req_id,
                                                "object": "chat.completion.chunk",
                                                "created": created_ts,
                                                "model": MODEL_ID,
                                                "choices": [
                                                    {
                                                        "index": 0,
                                                        "delta": delta_obj,
                                                        "finish_reason": None,
                                                    }
                                                ],
                                            }
                                            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode("utf-8"))
                                            self.wfile.flush()
                            elif line.startswith("STATS "):
                                for kv in line[6:].split():
                                    if "=" in kv:
                                        k, v = kv.split("=", 1)
                                        try:
                                            stats[k] = float(v) if "." in v else int(v)
                                        except ValueError:
                                            stats[k] = v

                        if err_msg:
                            if not stream:
                                self.send_json(500, {"error": {"message": err_msg, "type": "server_error"}})
                            return

                        prompt_n = int(stats.get("prompt_n", 0))
                        predicted_n = int(stats.get("predicted_n", 0))
                        prompt_ms = float(stats.get("prompt_prepare_ms", 1.0))
                        decode_ms = float(stats.get("decode_ms", 1.0))
                        wall_ms = float(stats.get("wall_ms", decode_ms))
                        predicted_per_sec = (predicted_n / (decode_ms / 1000.0)) if decode_ms > 0 else 0.0

                        timings = {
                            "prompt_n": prompt_n,
                            "prompt_ms": prompt_ms,
                            "predicted_n": predicted_n,
                            "predicted_ms": decode_ms,
                            "wall_ms": wall_ms,
                            "predicted_per_second": predicted_per_sec,
                            "diffusion_blocks": int(stats.get("blocks", 1)),
                            "diffusion_steps": int(stats.get("steps", 0)),
                        }
                        usage = {
                            "prompt_tokens": prompt_n,
                            "completion_tokens": predicted_n,
                            "total_tokens": prompt_n + predicted_n,
                        }

                        if stream:
                            end_chunk = {
                                "id": req_id,
                                "object": "chat.completion.chunk",
                                "created": created_ts,
                                "model": MODEL_ID,
                                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                                "usage": usage,
                                "timings": timings,
                            }
                            self.wfile.write(f"data: {json.dumps(end_chunk)}\n\ndata: [DONE]\n\n".encode("utf-8"))
                            self.wfile.flush()
                            return

                        reasoning_text, final_content = split_reasoning_and_content(committed_text)
                        if not final_content and reasoning_text:
                            final_content = reasoning_text

                        msg_obj = {"role": "assistant", "content": final_content}
                        if reasoning_text:
                            msg_obj["reasoning_content"] = reasoning_text

                        resp = {
                            "id": req_id,
                            "object": "chat.completion",
                            "created": created_ts,
                            "model": MODEL_ID,
                            "choices": [
                                {
                                    "index": 0,
                                    "message": msg_obj,
                                    "finish_reason": "stop",
                                }
                            ],
                            "usage": usage,
                            "timings": timings,
                        }
                        self.send_json(200, resp)
                finally:
                    try:
                        os.remove(req_path)
                    except OSError:
                        pass


        if __name__ == "__main__":
            WORKER = DiffusionGemmaWorker()
            server = ThreadingHTTPServer(("0.0.0.0", PORT), OpenAIHandler)
            print(f"[proxy] OpenAI-compatible DiffusionGemma server listening on http://0.0.0.0:{PORT}", flush=True)
            server.serve_forever()
    - require:
      - cmd: halo395_download_diffusiongemma_26b_a4b

# ==============================================================================
# 11. Systemd User Service: strix-llama-router.service (Resident DiffusionGemma)
# ==============================================================================
halo395_systemd_user_dir:
  file.directory:
    - name: {{ home }}/.config/systemd/user
    - user: {{ user }}
    - group: {{ user }}
    - makedirs: True
    - dir_mode: '0755'
    - require:
      - user: halo395_user_account

halo395_router_systemd_unit:
  file.managed:
    - name: {{ home }}/.config/systemd/user/strix-llama-router.service
    - user: {{ user }}
    - group: {{ user }}
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Strix Halo 128GB DiffusionGemma-26B-A4B OpenAI Server (PR #24423 Entropy-Bound)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        Environment="HOME={{ home }}"
        Environment="PATH={{ home }}/.local/bin:/usr/local/bin:/usr/bin:/bin"
        WorkingDirectory={{ home }}

        ExecStartPre=/usr/bin/podman start llama-vulkan-radv
        ExecStartPre=-/usr/bin/podman exec llama-vulkan-radv pkill -9 -f llama-server

        ExecStart=/usr/bin/toolbox run --container llama-vulkan-radv \
          /usr/bin/python3 {{ home }}/.local/bin/diffusion-openai-proxy.py

        ExecStop=/usr/bin/podman stop -t 10 llama-vulkan-radv
        Restart=on-failure
        RestartSec=10
        LimitMEMLOCK=infinity
        TimeoutStartSec=300

        [Install]
        WantedBy=default.target
    - require:
      - file: halo395_systemd_user_dir
      - file: halo395_diffusion_openai_proxy
      - cmd: inference-backend-header

halo395_enable_and_start_router_service:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user enable --now strix-llama-router.service
    - runas: {{ user }}
    - unless: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        systemctl --user is-active --quiet strix-llama-router.service
    - require:
      - cmd: halo395_enable_linger
      - cmd: halo395_create_vulkan_toolbox
      - cmd: halo395_build_llama_pr24423_diffusion
      - file: halo395_diffusion_openai_proxy
      - file: halo395_router_systemd_unit

halo395_restart_router_on_config_change:
  cmd.run:
    - name: |
        export XDG_RUNTIME_DIR="/run/user/$(id -u {{ user }})"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
        systemctl --user daemon-reload
        systemctl --user restart strix-llama-router.service
    - runas: {{ user }}
    - onchanges:
      - cmd: halo395_build_llama_pr24423_diffusion
      - file: halo395_diffusion_openai_proxy
      - file: halo395_router_systemd_unit
    - require:
      - cmd: halo395_enable_and_start_router_service