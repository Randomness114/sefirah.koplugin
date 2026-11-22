#!/usr/bin/env python3
"""Crée une extension pour un site au thème MangaThemesia en 1 commande.

  python3 tools/new_mangathemesia.py <id> "<Nom>" <domaine> <langue> [chemin_liste]
  ex. : python3 tools/new_mangathemesia.py mangascantrad "Manga-Scantrad" manga-scantrad.io fr
        (chemin_liste : "/manga/" par défaut ; Sushiscan utilise "/catalogue/")

Le fichier est créé dans extensions/<id>.lua ; Sefirah le détecte tout seul.
Astuce : si la liste est vide, ouvre <domaine>/manga/ et <domaine>/catalogue/ dans un navigateur
pour voir lequel marche, puis relance avec le bon chemin_liste.
"""
import os, re, sys

if len(sys.argv) < 5:
    sys.exit(__doc__)
ext_id, name, host, lang = sys.argv[1:5]
list_path = sys.argv[5] if len(sys.argv) > 5 else "/manga/"
if not re.fullmatch(r"[A-Za-z0-9_-]+", ext_id):
    sys.exit("id invalide (lettres, chiffres, _ et - seulement)")
host = re.sub(r"^https?://", "", host).split("/")[0].removeprefix("www.")
here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "extensions", ext_id + ".lua")
if os.path.exists(out):
    sys.exit(f"{out} existe déjà")
open(out, "w", encoding="utf-8").write(f'''-- {name} ({host}) — thème MangaThemesia. Code : core/mangathemesia.lua
return require("core.mangathemesia").new{{
    id = "{ext_id}", name = "{name}", host = "{host}", lang = "{lang}", version = "1.0.0",
    listPath = "{list_path}",
    -- optionnel : hide_titles = {{ ["titre"] = true }}, hide_words = {{ "18+" }}, genres = {{ {{ id = "action", label = "Action" }} }}
}}
''')
print("Créé :", os.path.normpath(out))
