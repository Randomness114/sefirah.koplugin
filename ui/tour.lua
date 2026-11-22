-- ui/tour.lua — visite guidée générique : cadre autour de l'élément visé,
-- flèche dessinée et bulle d'explication avec Passer / Retour / Suivant.
-- Inspirée de la visite de MemDeck. Aucune image : tout est dessiné au pixel,
-- donc net en e-ink et en mode nuit.
--
-- Usage :
--   Tour.run({
--     { title = "…", body = "…",
--       prepare = function() … end,            -- optionnel : changer d'onglet, etc.
--       target  = function() return Geom end,   -- optionnel : zone à entourer
--       side    = "above" | "below",            -- optionnel : côté de la bulle
--       primary = { text = "…", action = function(next) … next() end },
--     }, … }, { on_finish = function() … end })
local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local T = require("core.i18n").T

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local DARK = Blitbuffer.COLOR_DARK_GRAY
local function sc(n) return Screen:scaleBySize(n) end

local Tour = {}

local TourOverlay = InputContainer:extend{
    step = nil, idx = 1, total = 1,
    on_next = nil, on_back = nil, on_skip = nil,
}

local function face(size) return Font:getFace("cfont", size) end

-- Bouton dessiné à la main (texte centré dans un cadre) : primaire = fond noir.
local function make_button(label, primary, w, h)
    local b = sc(2)
    return FrameContainer:new{
        bordersize = b, color = BLACK, radius = sc(6), margin = 0, padding = 0,
        background = primary and BLACK or WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b },
            TextWidget:new{ text = label, face = face(17), bold = true, fgcolor = primary and WHITE or BLACK },
        },
    }
end

function TourOverlay:init()
    local SW, SH = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = SW, h = SH }
    if Device:hasKeys() then
        self.key_events = { Skip = { { Device.input.group.Back } } }
    end
    self.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },   -- évite de fermer l'écran dessous par un glissement
    }

    local st = self.step
    local margin = sc(12)
    local bw = SW - 2 * margin
    local border, pad = sc(2), sc(14)
    local inner_w = bw - 2 * border - 2 * pad

    -- Zone entourée (légèrement agrandie) ; ignorée si elle n'a pas encore été dessinée.
    local hl
    if st.target then
        local ok, r = pcall(st.target)
        if ok and r and r.w and r.h and r.w > 0 and r.h > 0 and not (r.x == 0 and r.y == 0) then
            local e = sc(5)
            hl = Geom:new{ x = math.max(0, r.x - e), y = math.max(0, r.y - e),
                           w = math.min(SW, r.w + 2 * e), h = r.h + 2 * e }
            if hl.x + hl.w > SW then hl.w = SW - hl.x end
            if hl.y + hl.h > SH then hl.h = SH - hl.y end
        end
    end
    self.hl = hl

    -- Boutons : Passer à gauche ; Retour + bouton principal à droite.
    local bh = sc(46)
    local function btn_w(label, min) return math.max(sc(min), TextWidget:new{ text = label, face = face(17), bold = true }:getSize().w + sc(28)) end
    local last = self.idx >= self.total
    local primary_label = (st.primary and st.primary.text) or (last and T("Terminer") or T("Suivant"))
    local left, right = {}, {}
    if not last then left[#left + 1] = { id = "skip", label = T("Passer"), w = btn_w(T("Passer"), 96) } end
    if self.idx > 1 then right[#right + 1] = { id = "back", label = T("Retour"), w = btn_w(T("Retour"), 96) } end
    right[#right + 1] = { id = "next", label = primary_label, primary = true, w = btn_w(primary_label, 120) }

    local gapw = sc(8)
    local lw, rw = 0, 0
    for _, b in ipairs(left) do lw = lw + b.w + gapw end
    for _, b in ipairs(right) do rw = rw + b.w + gapw end
    -- Si les boutons ne tiennent pas sur une ligne, on supprime « Passer ».
    if lw + (rw - gapw) > inner_w and #left > 0 then left = {}; lw = 0 end

    local row = HorizontalGroup:new{ align = "center" }
    for _, b in ipairs(left) do
        row[#row + 1] = make_button(b.label, false, b.w, bh)
        row[#row + 1] = HorizontalSpan:new{ width = gapw }
    end
    row[#row + 1] = HorizontalSpan:new{ width = math.max(0, inner_w - lw - (rw - gapw)) }
    for i, b in ipairs(right) do
        row[#row + 1] = make_button(b.label, b.primary, b.w, bh)
        if i < #right then row[#row + 1] = HorizontalSpan:new{ width = gapw } end
    end

    -- Contenu de la bulle.
    local counter = TextWidget:new{ text = ("%d/%d"):format(self.idx, self.total), face = face(14), fgcolor = DARK }
    local title = TextBoxWidget:new{ text = st.title or "", face = face(20), bold = true, width = inner_w }
    local body = TextBoxWidget:new{ text = st.body or "", face = face(16), width = inner_w, alignment = "left" }
    local g1, g2 = sc(6), sc(14)
    local content = VerticalGroup:new{ align = "left",
        counter, VerticalSpan:new{ width = g1 }, title, VerticalSpan:new{ width = g1 },
        body, VerticalSpan:new{ width = g2 }, row,
    }
    local bubble = FrameContainer:new{
        bordersize = border, color = BLACK, radius = sc(10), margin = 0, padding = pad,
        background = WHITE, width = bw, content,
    }
    local bsz = bubble:getSize()
    local bub_h = bsz.h

    -- Placement : au-dessus si la cible est dans la moitié basse, sinon en dessous.
    local arrow_gap = sc(46)
    local by, side
    if hl then
        side = st.side or ((hl.y + hl.h / 2) > SH / 2 and "above" or "below")
        local function fits(s)
            if s == "above" then return hl.y - arrow_gap - bub_h >= margin end
            return hl.y + hl.h + arrow_gap + bub_h <= SH - margin
        end
        if not fits(side) then side = (side == "above") and "below" or "above" end
        if side == "above" then by = hl.y - arrow_gap - bub_h else by = hl.y + hl.h + arrow_gap end
        by = math.max(margin, math.min(by, SH - margin - bub_h))
    else
        by = math.floor((SH - bub_h) / 2)
    end
    self.side, self.bubble, self.bx, self.by, self.bw, self.bh = side, bubble, margin, by, bw, bub_h

    -- Zones tactiles des boutons (positions calculées ici : la mise en page est déterministe).
    local ix = margin + border + pad
    local iy = by + border + pad + counter:getSize().h + g1 + title:getSize().h + g1 + body:getSize().h + g2
    self.btn_rects = {}
    local x = ix
    for _, b in ipairs(left) do
        self.btn_rects[#self.btn_rects + 1] = { id = b.id, r = Geom:new{ x = x, y = iy, w = b.w, h = bh } }
        x = x + b.w + gapw
    end
    x = ix + inner_w - (rw - gapw)
    for _, b in ipairs(right) do
        self.btn_rects[#self.btn_rects + 1] = { id = b.id, r = Geom:new{ x = x, y = iy, w = b.w, h = bh } }
        x = x + b.w + gapw
    end
end

function TourOverlay:paintTo(bb, x, y)
    local hl = self.hl
    if hl then
        -- Cadre épais autour de la cible, avec un filet blanc extérieur pour le détacher du fond.
        local t = sc(3)
        local function frame(rx, ry, rw, rh, th, color)
            bb:paintRect(rx, ry, rw, th, color)
            bb:paintRect(rx, ry + rh - th, rw, th, color)
            bb:paintRect(rx, ry, th, rh, color)
            bb:paintRect(rx + rw - th, ry, th, rh, color)
        end
        frame(hl.x - 2, hl.y - 2, hl.w + 4, hl.h + 4, 2, WHITE)
        frame(hl.x, hl.y, hl.w, hl.h, t, BLACK)

        -- Flèche verticale entre la bulle et la cible.
        local tcx = hl.x + math.floor(hl.w / 2)
        local ax = math.max(self.bx + sc(30), math.min(tcx, self.bx + self.bw - sc(30)))
        ax = math.max(hl.x + sc(12), math.min(ax, hl.x + hl.w - sc(12)))
        local head_w, head_h, shaft_w = sc(30), sc(20), sc(5)
        if self.side == "above" then
            local y0 = self.by + self.bh              -- bas de la bulle
            local tip = hl.y - sc(4)                  -- pointe, juste au-dessus du cadre
            bb:paintRect(ax - math.floor(shaft_w / 2), y0, shaft_w, math.max(0, tip - head_h - y0), BLACK)
            for i = 0, head_h - 1 do
                local rw = math.max(1, math.floor(head_w * (head_h - i) / head_h))
                bb:paintRect(ax - math.floor(rw / 2), tip - head_h + i, rw, 1, BLACK)
            end
        else
            local y0 = self.by                        -- haut de la bulle
            local tip = hl.y + hl.h + sc(4)           -- pointe, juste sous le cadre
            bb:paintRect(ax - math.floor(shaft_w / 2), tip + head_h, shaft_w, math.max(0, y0 - tip - head_h), BLACK)
            for i = 0, head_h - 1 do
                local rw = math.max(1, math.floor(head_w * (head_h - i) / head_h))
                bb:paintRect(ax - math.floor(rw / 2), tip + head_h - 1 - i, rw, 1, BLACK)
            end
        end
    end
    self.bubble:paintTo(bb, self.bx, self.by)
end

function TourOverlay:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function TourOverlay:onTap(_, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    for _, b in ipairs(self.btn_rects) do
        if pos:intersectWith(b.r) then
            if b.id == "skip" then self.on_skip()
            elseif b.id == "back" then self.on_back()
            else self.on_next() end
            return true
        end
    end
    -- Toucher la zone entourée = passer à l'étape suivante (comme si on l'avait touchée).
    if self.hl and pos:intersectWith(self.hl) then self.on_next() end
    return true       -- l'écran en dessous ne reçoit jamais le toucher pendant la visite
end

function TourOverlay:onSwipe() return true end

function TourOverlay:onSkip() self.on_skip(); return true end

-- ── Pilotage des étapes ─────────────────────────────────────────────────────
function Tour.run(steps, opts)
    opts = opts or {}
    local current
    local show

    local function close_current()
        if current then UIManager:close(current); current = nil end
    end
    local function finish()
        close_current()
        if opts.on_finish then pcall(opts.on_finish) end
    end
    local function goto_step(i)
        close_current()
        if i < 1 then i = 1 end
        if i > #steps then return finish() end
        if opts.alive and not opts.alive() then return finish() end
        local st = steps[i]
        if st.prepare then
            local ok, err = pcall(st.prepare)
            if not ok then pcall(function() require("logger").warn("Sefirah visite guidée :", err) end) end
        end
        -- Laisse l'écran se redessiner (changement d'onglet) avant de mesurer la cible.
        UIManager:scheduleIn(st.delay or (st.prepare and 0.3 or 0), function() show(i) end)
    end
    show = function(i)
        if opts.alive and not opts.alive() then return finish() end
        local raw = steps[i]
        local st = {}
        for k, v in pairs(raw) do st[k] = v end
        if type(raw.body) == "function" then st.body = raw.body() end
        if type(raw.primary) == "function" then st.primary = raw.primary() or nil end
        local function nxt() goto_step(i + 1) end
        local ok, err = pcall(function()
            current = TourOverlay:new{
                step = st, idx = i, total = #steps,
                on_next = function()
                    if st.primary and st.primary.action then
                        close_current()
                        local ok2, e2 = pcall(st.primary.action, function() goto_step(i + 1) end)
                        if not ok2 then pcall(function() require("logger").warn("Sefirah visite guidée :", e2) end); goto_step(i + 1) end
                    else
                        nxt()
                    end
                end,
                on_back = function() goto_step(i - 1) end,
                on_skip = finish,
            }
            UIManager:show(current)
        end)
        if not ok then
            pcall(function() require("logger").warn("Sefirah visite guidée :", err) end)
            current = nil
            finish()
        end
    end
    goto_step(1)
end

return Tour
