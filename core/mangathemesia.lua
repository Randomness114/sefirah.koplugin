-- core/mangathemesia.lua — moteur générique pour les sites au thème « MangaThemesia » (MangaStream / ts-reader).
-- Une extension = un petit fichier extensions/<id>.lua qui appelle  require("core.mangathemesia").new{ … }.
-- Tout le reste (liste, filtres, recherche, fiche, chapitres, pages, adresse modifiable) est ici, une seule fois.
--
-- Options (cfg) :
--   id, name, host, lang, version          (obligatoires : id = nom du fichier)
--   listPath    "/manga/"  chemin de la liste (Sushiscan : "/catalogue/")
--   genres      { {id="action", label="Action"}, … }  liste de départ (relue sur le site si possible)
--   hide_titles { ["titre en minuscules"]=true }       fiches à masquer dans les listes
--   hide_words  { "18+", … }                           mots qui masquent une carte (contenu adulte)
--   default_order "popular" | "update" | "latest" | "title" | "titlereverse"
--   cover_budget  nombre max de fiches lues pour retrouver une couverture manquante (défaut 8)
--   ua          User-Agent
local logger = require("logger")
local T = require("core.i18n").T
local M = {}

-- ───────────────────────── utilitaires texte / HTML ─────────────────────────
local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—", laquo = "«", raquo = "»",
    eacute = "é", egrave = "è", ecirc = "ê", euml = "ë", agrave = "à", acirc = "â", ccedil = "ç", icirc = "î", iuml = "ï",
    ocirc = "ô", ugrave = "ù", ucirc = "û", uuml = "ü", oelig = "œ", Eacute = "É", Egrave = "È", Agrave = "À", Ccedil = "Ç" }
local function dec(s)
    if not s then return s end
    return (s:gsub("&(#?%w+);", function(e)
        local n = e:match("^#[xX](%x+)$")
        if n then return cp2utf8(tonumber(n, 16)) end
        n = e:match("^#(%d+)$")
        if n then return cp2utf8(tonumber(n)) end
        return ENT[e]
    end))
end
local function trim(s) return ((s or ""):match("^%s*(.-)%s*$")) end
local function txt(h)
    h = (h or ""):gsub("<[^>]+>", " ")
    h = dec(h):gsub("%s+", " ")
    return trim(h)
end
local NL = string.char(10)
local function para(h)
    h = (h or ""):gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    h = h:gsub("</p>", NL .. NL):gsub("<br%s*/?>", NL):gsub("<[^>]+>", "")
    h = dec(h):gsub(string.char(13), ""):gsub(" +", " ")
    h = h:gsub(" *" .. NL .. " *", NL):gsub(NL .. NL .. "+", NL .. NL)
    return trim(h)
end
local function attr(tag, n)
    if not tag then return nil end
    local k = "%f[%w_%-]" .. n:gsub("%-", "%%-") .. "%s*=%s*"
    return tag:match(k .. '"([^"]*)"') or tag:match(k .. "'([^']*)'")
end
local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function norm(h)
    h = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", "")
    return h:lower()
end
local function bad_cover(u)
    local last = (u:gsub("[?#].*$", ""):match("([^/]*)$") or ""):lower()
    return last == "" or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
end
local function unescape_json(u)
    u = u:gsub("\\u(%x%x%x%x)", function(h) return cp2utf8(tonumber(h, 16)) end)
    return (u:gsub("\\/", "/"))
end

-- contenu équilibré de la balise ouverte juste avant `from` (gère les <div> imbriquées)
local function inner(html, from, tn)
    local open, close = "<" .. tn, "</" .. tn
    local depth, p = 1, from
    while true do
        local a = html:find(open, p, true)
        local b = html:find(close, p, true)
        if not b then return nil end
        if a and a < b then
            if not html:sub(a + #open, a + #open):match("[%w]") then depth = depth + 1 end
            p = a + #open
        else
            if not html:sub(b + #close, b + #close):match("[%w]") then
                depth = depth - 1
                if depth == 0 then return html:sub(from, b - 1) end
            end
            p = b + #close
        end
    end
end
-- contenu de l'élément qui contient `needle` dans sa balise ouvrante (ex. 'id="chapterlist"')
local function block_with(html, needle, from)
    local p = html:find(needle, from or 1, true)
    if not p then return nil end
    local ts = p
    while ts > 1 and html:sub(ts, ts) ~= "<" do ts = ts - 1 end
    local tn = html:match("^<(%a%w*)", ts)
    local _, e = html:find(">", p, true)
    if not (tn and e) then return nil end
    return inner(html, e + 1, tn), ts
end
-- tous les blocs dont la classe CONTIENT le mot `cls` (mot entier)
local function blocks_by_class(html, cls)
    local out, pos = {}, 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then break end
        local c = attr(attrs, "class")
        if c and (" " .. c .. " "):find(" " .. cls .. " ", 1, true) then
            local body = inner(html, e + 1, tn)
            if body then out[#out + 1] = body end
        end
        pos = e + 1
    end
    return out
end

-- ───────────────────────── le moteur ─────────────────────────
function M.new(cfg)
    local ID = assert(cfg.id, "mangathemesia: id manquant")
    local DEFAULT_HOST = assert(cfg.host, "mangathemesia: host manquant")
    local LISTP = cfg.listPath or "/manga/"
    local UA = cfg.ua or "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
    local HIDE_T, HIDE_W = cfg.hide_titles or {}, cfg.hide_words or {}
    local COVER_BUDGET = cfg.cover_budget or 8

    -- adresse (modifiable dans Sources ▸ ⚙)
    local function clean_host(h)
        h = tostring(h or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%a+://", ""):gsub("/.*$", ""):gsub("^www%.", "")
        if h:match("^[%w%-]+%.[%w%.%-]+$") then return h:lower() end
        return nil
    end
    local function saved_host()
        local ok, S = pcall(require, "sefirah_settings")
        if not ok or not S then return nil end
        local ok2, v = pcall(function() return S:getExt(ID, "host", nil) end)
        return ok2 and clean_host(v) or nil
    end
    local HOST = saved_host() or clean_host(DEFAULT_HOST)
    local BASE = "https://" .. HOST
    local ok_bp, Bypass = pcall(require, "core.dnsbypass")
    if ok_bp and Bypass then Bypass.register(HOST) else Bypass = nil end

    local function get(p)
        local url = p:match("^https?://") and p or (BASE .. p)
        local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 20 })
        if body and #body > 2 then return body end
        logger.warn(cfg.name .. ": échec", url, tostring(code))
        return nil, tostring(code)
    end
    local function abs(u)
        if not u or u == "" then return nil end
        if u:sub(1, 2) == "//" then return "https:" .. u end
        if u:sub(1, 1) == "/" then return BASE .. u end
        if not u:match("^https?://") then return BASE .. "/" .. u end
        return u
    end
    local function rel(h)
        h = h:gsub("^https?://[^/]+", "")
        if h:sub(1, 1) ~= "/" then h = "/" .. h end
        return h
    end
    local function cover_of(img)
        if not img then return nil end
        for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset", "data-srcset" }) do
            local u = attr(img, k)
            if (k == "srcset" or k == "data-srcset") and u then u = u:match("^%s*(%S+)") end
            if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true)
               and not u:lower():find("blank", 1, true) and not bad_cover(u) then
                return abs(dec(u))
            end
        end
        return nil
    end

    local function hidden(name, card)
        if HIDE_T[trim(name or ""):lower()] then return true end
        if #HIDE_W > 0 then
            local low = (card or ""):lower()
            for _, w in ipairs(HIDE_W) do if low:find(w, 1, true) then return true end end
        end
        return false
    end

    -- ── liste (cartes .bsx ; repli : liens vers /<listPath>/<slug>/) ──
    local function is_work(href)
        local n = norm(href)
        local a = n:find(LISTP:lower():gsub("/+$", ""), 1, true)
        if not a then return false end
        local after = n:sub(a + #(LISTP:gsub("/+$", "")))
        after = after:gsub("^/", "")
        return after ~= "" and not after:find("/", 1, true)
    end
    local function parse_list(html)
        local res, idx = {}, {}
        local function add(href, name, cover, card)
            if not href or href == "" then return end
            name = trim(dec(name or ""))
            if name == "" or hidden(name, card) then return end
            local k = norm(href)
            local it = idx[k]
            if it then
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover }
                idx[k] = it
                res[#res + 1] = it
            end
        end
        -- 1) cartes MangaThemesia
        local pos = 1
        while true do
            local p = html:find('class="bsx"', pos, true) or html:find("class='bsx'", pos, true)
            if not p then break end
            local body
            local ts = p
            while ts > 1 and html:sub(ts, ts) ~= "<" do ts = ts - 1 end
            local tn = html:match("^<(%a%w*)", ts) or "div"
            local _, e = html:find(">", p, true)
            body = e and inner(html, e + 1, tn) or nil
            if body then
                local a = body:match("<a%s[^>]->")
                local img = body:match("<img[^>]->")
                local name = attr(a, "title") or (img and attr(img, "alt")) or ""
                if name == "" then
                    local tt = body:match('class="tt"[^>]*>(.-)</div>')
                    name = tt and txt(tt) or ""
                end
                add(a and attr(a, "href"), name, cover_of(img), body)
                pos = e + #body
            else
                pos = (e or p) + 1
            end
        end
        -- 2) repli : n'importe quel lien vers une fiche
        if #res == 0 then
            for tag, in_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
                local href = attr(tag, "href")
                if href and is_work(href) then
                    local img = in_html:match("<img[^>]->")
                    local name = attr(tag, "title") or (img and attr(img, "alt")) or txt(in_html)
                    add(href, name, cover_of(img), in_html)
                end
            end
        end
        -- couvertures manquantes : og:image de la fiche (quelques-unes seulement, pour rester rapide)
        local budget = COVER_BUDGET
        for _, it in ipairs(res) do
            if not it.cover and budget > 0 then
                budget = budget - 1
                local ok, page = pcall(get, it.path)
                if ok and page then
                    local og = page:match('property="og:image"[^>]-content="([^"]*)"') or page:match('content="([^"]*)"[^>]-property="og:image"')
                    if og and og ~= "" and not bad_cover(og) then it.cover = abs(dec(og)) end
                end
            end
        end
        return res
    end

    -- ── filtres (valeurs standard du thème) ──
    local function opts(list) local o = {} for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end return o end
    local ORDER_F = { key = "order", label = "Tri", default = cfg.default_order or "popular", options = opts({
        { "popular", "Populaires" }, { "update", "Dernière mise à jour" }, { "latest", "Derniers ajouts" },
        { "title", "A → Z" }, { "titlereverse", "Z → A" } }) }
    local STATUS_F = { key = "status", label = "Statut", default = "all", options = opts({
        { "all", "Tous" }, { "ongoing", "En cours" }, { "completed", "Terminé" }, { "hiatus", "En pause" } }) }
    local TYPE_F = { key = "type", label = "Type", default = "all", options = opts({
        { "all", "Tous" }, { "Manga", "Manga" }, { "Manhwa", "Manhwa" }, { "Manhua", "Manhua" }, { "Comic", "Comic" } }) }
    local function genre_opts(list)
        local o = { { id = "all", label = "Tous" } }
        for _, g in ipairs(list or {}) do
            if type(g) == "table" then o[#o + 1] = { id = g.id, label = g.label or g.id } end
        end
        return o
    end
    local GENRE_F = { key = "genre", label = "Genres", default = "", multi = true, options = genre_opts(cfg.genres) }
    local FILTERS = { ORDER_F, STATUS_F, TYPE_F }
    if cfg.genres and #cfg.genres > 0 then FILTERS[#FILTERS + 1] = GENRE_F end

    local function fval(f, k)
        local v = f and f[k]
        if v == nil or v == "" or v == "all" then return nil end
        return tostring(v)
    end
    local function list_url(page, filters)
        local q = {}
        q[#q + 1] = "page=" .. tostring(page or 1)
        local o = fval(filters, "order") or ORDER_F.default
        if o and o ~= "all" then q[#q + 1] = "order=" .. enc(o) end
        local s = fval(filters, "status"); if s then q[#q + 1] = "status=" .. enc(s) end
        local t = fval(filters, "type");   if t then q[#q + 1] = "type=" .. enc(t) end
        local g = fval(filters, "genre")
        if g then for x in g:gmatch("[^,]+") do q[#q + 1] = "genre%5B%5D=" .. enc(x) end end
        return BASE .. LISTP .. "?" .. table.concat(q, "&")
    end

    local ext = { id = ID, name = cfg.name or ID, site = BASE, lang = cfg.lang or "en", version = cfg.version or "1.0.0",
        type = "manga", popularFilters = FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

    function ext:popularNovels(page, options)
        page = tonumber(page) or 1
        local html, err = get(list_url(page, options and options.filters))
        if not html then
            if page > 1 then return { novels = {} } end -- fin de la liste
            return { novels = {}, error = T("Site injoignable (") .. tostring(err) .. ")" }
        end
        return { novels = parse_list(html) }
    end

    function ext:searchNovels(term, page, options)
        term = trim(tostring(term or ""))
        if term == "" then return ext:popularNovels(page, options) end
        page = tonumber(page) or 1
        local url = (page > 1 and (BASE .. "/page/" .. page .. "/") or (BASE .. "/")) .. "?s=" .. enc(term)
        local html, err = get(url)
        if not html then
            if page > 1 then return { novels = {} } end
            return { novels = {}, error = T("Recherche impossible (") .. tostring(err) .. ")" }
        end
        return { novels = parse_list(html) }
    end

    -- genres relus sur le site (la liste intégrée sert de secours)
    function ext:loadFilters()
        local html = get(LISTP)
        if html then
            local list, seen = {}, {}
            for tag, rest in html:gmatch('(<input[^>]-name="genre%[%]"[^>]->)(.-)</li>') do
                local v = attr(tag, "value")
                local label = rest:match("<label[^>]*>(.-)</label>")
                label = label and txt(label):gsub("%s*%(%d+%)%s*$", "") or nil
                if v and v ~= "" and not seen[v] then
                    seen[v] = true
                    list[#list + 1] = { id = v, label = (label and label ~= "") and label or v }
                end
            end
            if #list >= 5 then GENRE_F.options = genre_opts(list)
                local have = false
                for _, f in ipairs(FILTERS) do if f == GENRE_F then have = true end end
                if not have then FILTERS[#FILTERS + 1] = GENRE_F end
            end
        end
        self.filters_ready = true
    end

    -- ── fiche ──
    local function meta(html, path)
        local name
        local h1 = html:match('<h1[^>]-class="[^"]-entry%-title[^"]-"[^>]*>(.-)</h1>') or html:match("<h1[^>]*>(.-)</h1>")
        name = h1 and txt(h1) or ""
        if name == "" then name = trim(dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "")):gsub("%s+[–%-|]%s+[^–%-|]+$", "") end
        if name == "" then name = path end

        local cover
        local thumb = block_with(html, 'class="thumb"') or block_with(html, "class='thumb'")
        if thumb then cover = cover_of(thumb:match("<img[^>]->")) end
        if not cover then
            local og = html:match('property="og:image"[^>]-content="([^"]*)"') or html:match('content="([^"]*)"[^>]-property="og:image"')
            if og and og ~= "" and not bad_cover(og) then cover = abs(dec(og)) end
        end

        local summary = ""
        local d = block_with(html, 'itemprop="description"') or block_with(html, 'class="entry-content entry-content-single"')
        if d then summary = para(d) end
        if #summary < 20 then
            summary = dec(html:match('property="og:description"[^>]-content="([^"]*)"')
                or html:match('content="([^"]*)"[^>]-property="og:description"')
                or html:match('name="description"[^>]-content="([^"]*)"') or "")
        end

        local author, status, genres = "", "", {}
        local function setkv(k, v)
            k, v = txt(k):lower():gsub("[:：]%s*$", ""), txt(v)
            if v == "" or v == "-" then return end
            if (k:find("auteur", 1, true) or k:find("author", 1, true)) and author == "" then author = v
            elseif (k:find("statut", 1, true) or k:find("status", 1, true)) and status == "" then status = v end
        end
        for lab, val in html:gmatch('class="imptdt"[^>]*>(.-)<i[^>]*>(.-)</i>') do setkv(lab, val) end
        for lab, val in html:gmatch('class="fmed"[^>]*>%s*<b>(.-)</b>%s*<span[^>]*>(.-)</span>') do setkv(lab, val) end
        for lab, val in html:gmatch("<tr[^>]*>%s*<td[^>]*>(.-)</td>%s*<td[^>]*>(.-)</td>") do setkv(lab, val) end
        local mg = block_with(html, 'class="mgen"') or block_with(html, "class='mgen'")
        if mg then
            for a in mg:gmatch("<a[^>]*>(.-)</a>") do local g = txt(a); if g ~= "" then genres[#genres + 1] = g end end
        end
        return { name = name, path = path, cover = cover, summary = summary, author = author, status = status, genres = genres }
    end

    function ext:parseNovelMeta(path)
        local html = get(path); if not html then return nil end
        local m = meta(html, path); m.total_chapters = 0; return m
    end

    function ext:parseNovel(path)
        local html = get(path); if not html then return nil end
        local m, ch, seen = meta(html, path), {}, {}
        local list_html = block_with(html, 'id="chapterlist"') or block_with(html, "id='chapterlist'")
        for tag, in_html in (list_html or html):gmatch("(<a%s[^>]->)(.-)</a>") do
            local href = attr(tag, "href")
            local ok = href and href ~= "" and not href:find("^#")
            if ok and list_html then
                ok = not tag:find("dload", 1, true) and not tag:find("download", 1, true) and not href:find("[?#]")
            elseif ok then
                ok = norm(href):find("chapitre", 1, true) or norm(href):find("chapter", 1, true)
            end
            if ok then
                local k = norm(href)
                local num = in_html:match('class="chapternum"[^>]*>(.-)</span>')
                local name = txt(num or in_html)
                if name == "" then name = trim(dec(attr(tag, "title") or "")) end
                if seen[k] then
                    if #name > #seen[k].name then seen[k].name = name end
                else
                    if name == "" then name = "Chapitre " .. (#ch + 1) end
                    seen[k] = { name = name, path = rel(href) }
                    ch[#ch + 1] = seen[k]
                end
            end
        end
        -- ordre : plus ancien d'abord (le thème liste le plus récent en premier)
        local function first_num(c) return tonumber((c.name or ""):match("(%d+%.?%d*)")) end
        local a1, b1 = first_num(ch[1] or {}), first_num(ch[#ch] or {})
        if not (a1 and b1 and a1 < b1) then
            for i = 1, math.floor(#ch / 2) do ch[i], ch[#ch + 1 - i] = ch[#ch + 1 - i], ch[i] end
        end
        for i, c in ipairs(ch) do c.chapter_number = i end
        m.chapters, m.totalPages = ch, 1
        return m
    end

    -- ── pages du chapitre : <img> de #readerarea ET/OU liste "images" du script ts_reader ──
    function ext:parseChapterImages(path)
        local html = get(path); if not html then return nil, "chapter_unreachable" end
        local function clean(u)
            u = u and abs(dec(trim(u)))
            if not u or not u:match("^https?://") or u:lower():find("logo", 1, true) then return nil end
            return u
        end
        local from_html, seen = {}, {}
        local block = block_with(html, 'id="readerarea"') or block_with(html, "id='readerarea'")
        for tag in (block or ""):gmatch("<img[^>]->") do
            local u = clean(attr(tag, "data-src") or attr(tag, "data-lazy-src") or attr(tag, "data-original") or attr(tag, "src"))
            if u and not seen[u] then seen[u] = true; from_html[#from_html + 1] = u end
        end
        local from_script, seen2 = {}, {}
        for arr in html:gmatch('"images"%s*:%s*(%b[])') do
            local tmp, n = {}, 0
            for raw in arr:gmatch('"(.-)"') do
                local u = clean(unescape_json(raw))
                if u and not seen2[u] then seen2[u] = true; tmp[#tmp + 1] = u; n = n + 1 end
            end
            if n > #from_script then from_script = tmp end
        end
        local images = from_html
        if #from_html < 2 and #from_script > #from_html then images = from_script end
        if #images == 0 then return nil, "no_pages" end
        return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
    end

    function ext:parseChapter() return "<p>Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.</p>" end

    -- ── adresse du site modifiable (Sources ▸ ⚙) ──
    function ext:setHost(h)
        h = clean_host(h)
        if not h then return false end
        HOST, BASE, self.site = h, "https://" .. h, "https://" .. h
        if Bypass then Bypass.register(h) end
        pcall(function() require("sefirah_settings"):setExt(ID, "host", h) end)
        return true
    end
    function ext:settingsRows(ctx)
        local P = require("ui.panel")
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local InputDialog = require("ui/widget/inputdialog")
        local T = require("core.i18n").T
        local self_ = self
        local function apply(h)
            if self_:setHost(h) then
                pcall(function() require("core.extmgr").refreshSite(ID, BASE) end)
                UIManager:show(InfoMessage:new{ text = T("Adresse enregistrée : ") .. BASE, timeout = 3 })
                ctx.reopen()
            else
                UIManager:show(InfoMessage:new{ text = T("Adresse invalide (ex. ") .. DEFAULT_HOST .. ")" })
            end
        end
        return {
            P.makeRow(T("Adresse du site : ") .. HOST, { callback = function()
                local dlg
                dlg = InputDialog:new{
                    title = T("Adresse du site"), input = HOST, input_hint = DEFAULT_HOST,
                    buttons = {{
                        { text = T("Annuler"), callback = function() UIManager:close(dlg) end },
                        { text = T("Enregistrer"), is_enter_default = true, callback = function()
                            local v = dlg:getInputText(); UIManager:close(dlg); apply(v) end },
                    }},
                }
                UIManager:show(dlg); dlg:onShowKeyboard()
            end }),
            P.makeRow(T("Rétablir l'adresse par défaut (") .. DEFAULT_HOST .. ")", { callback = function() apply(DEFAULT_HOST) end }),
        }
    end

    return ext
end

return M
