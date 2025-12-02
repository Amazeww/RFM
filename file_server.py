import os
from flask import Flask, jsonify, send_from_directory, request, abort
from werkzeug.utils import secure_filename

ROOT = os.path.expanduser("/")  # change to the folder you want to share
os.makedirs(ROOT, exist_ok=True)

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 4 * 1024 * 1024 * 1024  # 4GB limit

def safe_path(rel):
    path = os.path.normpath(os.path.join(ROOT, rel))
    if not path.startswith(ROOT):
        abort(400, "Bad path")
    return path

@app.route("/files", methods=["GET"])
def list_files():
    rel = request.args.get("path", "")
    path = safe_path(rel)
    if not os.path.exists(path):
        return jsonify({"error":"not found"}), 404
    if os.path.isfile(path):
        return jsonify({"error":"not a directory"}), 400
    entries = []
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        entries.append({
            "name": name,
            "is_dir": os.path.isdir(full),
            "size": os.path.getsize(full) if os.path.isfile(full) else None
        })
    return jsonify({"path": rel, "entries": entries})

@app.route("/download", methods=["GET"])
def download():
    rel = request.args.get("path", "")
    path = safe_path(rel)
    if not os.path.isfile(path):
        return jsonify({"error":"not found"}), 404
    folder, fname = os.path.split(path)
    return send_from_directory(folder, fname, as_attachment=True)

@app.route("/upload", methods=["POST"])
def upload():
    rel_dir = request.form.get("path", "")
    path_dir = safe_path(rel_dir)
    os.makedirs(path_dir, exist_ok=True)
    if 'file' not in request.files:
        return jsonify({"error":"no file part"}), 400
    f = request.files['file']
    filename = secure_filename(f.filename)
    dest = os.path.join(path_dir, filename)
    f.save(dest)
    return jsonify({"ok": True, "saved": filename})

@app.route("/mkdir", methods=["POST"])
def mkdir():
    rel = request.json.get("path", "")
    path = safe_path(rel)
    os.makedirs(path, exist_ok=True)
    return jsonify({"ok": True})

@app.route("/delete", methods=["POST"])
def delete():
    rel = request.json.get("path", "")
    path = safe_path(rel)
    if os.path.isdir(path):
        try:
            os.rmdir(path)
            return jsonify({"ok": True})
        except Exception as e:
            return jsonify({"error": str(e)}), 400
    elif os.path.isfile(path):
        os.remove(path)
        return jsonify({"ok": True})
    return jsonify({"error":"not found"}), 404

if __name__ == "__main__":
    # run with: python file_server.py
    # accessible on LAN at http://0.0.0.0:5000
    app.run(host="0.0.0.0", port=5000, debug=True)
