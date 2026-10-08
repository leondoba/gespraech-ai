"""Prépare le projet Android. Fichiers à la racine : pubspec.yaml, main.dart, setup.py"""
import re, subprocess, sys, pathlib
root = pathlib.Path(__file__).parent.resolve()
keep = {f: (root / f).read_text(encoding="utf-8") for f in ("pubspec.yaml", "main.dart")}
sh = sys.platform.startswith("win")
subprocess.run(["flutter", "create", "--org", "com.gespraech", "--project-name", "gespraech", "--platforms", "android", "."], cwd=root, check=True, shell=sh)
(root / "pubspec.yaml").write_text(keep["pubspec.yaml"], encoding="utf-8")
(root / "lib").mkdir(exist_ok=True)
(root / "lib" / "main.dart").write_text(keep["main.dart"], encoding="utf-8")
man = root / "android/app/src/main/AndroidManifest.xml"
m = man.read_text(encoding="utf-8")
if "RECORD_AUDIO" not in m:
    add = ('<uses-permission android:name="android.permission.INTERNET"/>\n'
           '    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\n'
           '    <queries>\n'
           '        <intent><action android:name="android.speech.RecognitionService"/></intent>\n'
           '        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>\n'
           '    </queries>\n    ')
    man.write_text(m.replace("<application", add + "<application", 1), encoding="utf-8")
for g in ("android/app/build.gradle", "android/app/build.gradle.kts"):
    p = root / g
    if p.exists():
        t = p.read_text(encoding="utf-8")
        t = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", lambda x: "minSdk = 24" if g.endswith("kts") else "minSdkVersion 24", t)
        p.write_text(t, encoding="utf-8")
print("OK")
