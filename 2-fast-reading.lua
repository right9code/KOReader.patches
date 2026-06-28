-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  Fast Reading — KOReader Patch (Fi                               ║
-- ║                                                                  ║
-- ║  Three reading-enhancement modes in a single patch:              ║
-- ║    1. Bionic Reading — bolds the first half of each word         ║
-- ║    2. Guided Dots    — places a middle-dot (·) between words     ║
-- ║    3. First Letter Focus — bolds the first letter/syllable       ║
-- ║                        each word (Devanagari-compound-aware)     ║
-- ║                                                                  ║
-- ║  Supported formats: EPUB, KEPUB, XHTML, HTML, HTM, MD, TXT       ║
-- ║  Menu location:     Typeset tab → above "Typography"             ║
-- ║                                                                  ║
-- ║  Features can be combined (e.g. Guided Dots + Bionic).           ║
-- ║  Bionic and First Letter Focus are mutually exclusive.           ║
-- ║  "Restore all books" undoes every modified book at once.         ║
-- ╚══════════════════════════════════════════════════════════════════╝

local userpatch = require("userpatch")
local lfs = require("libs/libkoreader-lfs")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Geom = require("ui/geometry")
local util = require("util")
local _ = require("gettext")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local PATCH_FLAG = "_intellireading_menu_patch_inplace"
local READERMENU_PATCH_FLAG = "_intellireading_readermenu_patch_inplace"
local LOOKUP_PATCH_FLAG = "_intellireading_bionic_lookup_patch_inplace"
local FEATURE_BIONIC = "bionic"
local FEATURE_GUIDED = "guided"
local FEATURE_ORP = "orp"
local BIONIC_MENU_KEY = "intellireading_bionic_reading"
local GUIDED_MENU_KEY = "intellireading_guided_dots"
local ORP_MENU_KEY = "intellireading_orp_reading"
local RESTORE_MENU_KEY = "intellireading_restore_all"
local BACKUP_SUFFIX = ".intellireading.orig"
local STATE_SUFFIX = ".intellireading.state"
local GUIDE_DOT_ENTITY = "&#183;" -- Numeric reference is safer than &middot;
local PROTECTED_TEXT_TAGS = {
    code = true,
    math = true,
    pre = true,
    script = true,
    style = true,
    svg = true,
    textarea = true,
    title = true,
}

local TOC_FILENAMES = {
    ["nav.xhtml"] = true,
    ["nav.html"] = true,
    ["toc.xhtml"] = true,
    ["toc.html"] = true,
}

local settings_path = DataStorage:getSettingsDir() .. "/intellireading.lua"

local function register_modified_book(file_path)
    local settings = LuaSettings:open(settings_path)
    local books = settings:readSetting("modified_books") or {}
    books[file_path] = true
    settings:saveSetting("modified_books", books)
    settings:flush()
end

local function unregister_modified_book(file_path)
    local settings = LuaSettings:open(settings_path)
    local books = settings:readSetting("modified_books") or {}
    books[file_path] = nil
    settings:saveSetting("modified_books", books)
    settings:flush()
end

local function get_extension(path)
    return (path:match("%.([^./\\]+)$") or ""):lower()
end

local function is_epub_path(path)
    local ext = get_extension(path)
    return ext == "epub" or ext == "kepub"
end

local function is_xhtml_path(path)
    local ext = get_extension(path)
    return ext == "xhtml" or ext == "html" or ext == "htm"
end

local function is_markdown_path(path)
    local ext = get_extension(path)
    return ext == "md" or ext == "txt"
end

local function is_supported_file(path)
    return is_epub_path(path) or is_xhtml_path(path) or is_markdown_path(path)
end

local function get_sdr_path(path)
    return path:gsub("%.([^.]+)$", "") .. ".sdr"
end

local function get_backup_path(path)
    local sdr = get_sdr_path(path)
    local ext = get_extension(path)
    return sdr .. "/backup." .. ext .. ".orig"
end

local function get_state_path(path)
    local sdr = get_sdr_path(path)
    return sdr .. "/intellireading.state"
end

local function dir_exists(path)
    return lfs.attributes(path, "mode") == "directory"
end

local function file_exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function copy_file(src, dst)
    local input = io.open(src, "rb")
    if not input then
        return nil, "unable to read source"
    end
    local data = input:read("*all")
    input:close()

    local temp = dst .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write target"
    end
    out:write(data)
    out:close()

    os.remove(dst)
    if not os.rename(temp, dst) then
        os.remove(temp)
        return nil, "unable to finalize target"
    end
    return true
end

local function normalize_feature_state(state)
    return {
        bionic = state and state.bionic and true or false,
        guided = state and state.guided and true or false,
        orp = state and state.orp and true or false,
    }
end

local function has_active_feature(state)
    return state and (state.bionic or state.guided or state.orp) or false
end

local function read_feature_state(path)
    local state = normalize_feature_state(nil)
    local state_path = get_state_path(path)
    local has_state_file = file_exists(state_path)

    if has_state_file then
        local input = io.open(state_path, "rb")
        if input then
            for line in input:lines() do
                local key, value = line:match("^([%a_]+)=([01])$")
                if key == FEATURE_BIONIC then
                    state.bionic = value == "1"
                elseif key == FEATURE_GUIDED then
                    state.guided = value == "1"
                elseif key == FEATURE_ORP then
                    state.orp = value == "1"
                end
            end
            input:close()
        end
    elseif file_exists(get_backup_path(path)) then
        state.bionic = true
    end

    return state
end

local function write_feature_state(path, state)
    local normalized = normalize_feature_state(state)
    local state_path = get_state_path(path)
    local temp = state_path .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write state"
    end

    out:write(FEATURE_BIONIC, "=", normalized.bionic and "1" or "0", "\n")
    out:write(FEATURE_GUIDED, "=", normalized.guided and "1" or "0", "\n")
    out:write(FEATURE_ORP, "=", normalized.orp and "1" or "0", "\n")
    out:close()

    os.remove(state_path)
    if not os.rename(temp, state_path) then
        os.remove(temp)
        return nil, "unable to finalize state"
    end
    return true
end

local function is_bionic_active_for_file(path)
    if not path then
        return false
    end
    return read_feature_state(path).bionic
end

local function is_guided_active_for_file(path)
    if not path then
        return false
    end
    return read_feature_state(path).guided
end

local function is_orp_active_for_file(path)
    if not path then
        return false
    end
    return read_feature_state(path).orp
end

-- UTF-8 Support Helper: Decode string to table of characters
local function utf8_chars(s)
    local chars = {}
    local i = 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        local char_len = 1
        if b >= 0xc0 and b <= 0xdf then
            char_len = 2
        elseif b >= 0xe0 and b <= 0xef then
            char_len = 3
        elseif b >= 0xf0 and b <= 0xf7 then
            char_len = 4
        end
        table.insert(chars, s:sub(i, i + char_len - 1))
        i = i + char_len
    end
    return chars
end

-- Decode UTF-8 character string to numeric Unicode Codepoint
local function utf8_codepoint(c)
    local len = #c
    if len == 1 then
        return c:byte(1)
    elseif len == 2 then
        local b1, b2 = c:byte(1, 2)
        return (b1 - 0xc0) * 64 + (b2 - 0x80)
    elseif len == 3 then
        local b1, b2, b3 = c:byte(1, 3)
        return (b1 - 0xe0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    elseif len == 4 then
        local b1, b2, b3, b4 = c:byte(1, 4)
        return (b1 - 0xf0) * 262144 + (b2 - 0x80) * 4096 + (b3 - 0x80) * 64 + (b4 - 0x80)
    end
    return 0
end

-- List of standard Unicode punctuation characters
local UNICODE_PUNCTUATION = {
    ["\xc2\xa0"] = true, -- NBSP
    ["\xc2\xa1"] = true, -- ¡
    ["\xc2\xab"] = true, -- «
    ["\xc2\xad"] = true, -- Soft hyphen
    ["\xc2\xb0"] = true, -- °
    ["\xc2\xb6"] = true, -- ¶
    ["\xc2\xb7"] = true, -- · (middle dot)
    ["\xc2\xbb"] = true, -- »
    ["\xc2\xbf"] = true, -- ¿
    ["\xe2\x80\x80"] = true, ["\xe2\x80\x81"] = true, ["\xe2\x80\x82"] = true,
    ["\xe2\x80\x83"] = true, ["\xe2\x80\x84"] = true, ["\xe2\x80\x85"] = true,
    ["\xe2\x80\x86"] = true, ["\xe2\x80\x87"] = true, ["\xe2\x80\x88"] = true,
    ["\xe2\x80\x89"] = true, ["\xe2\x80\x8a"] = true, ["\xe2\x80\x8b"] = true,
    ["\xe2\x80\x90"] = true, ["\xe2\x80\x91"] = true, ["\xe2\x80\x92"] = true,
    ["\xe2\x80\x93"] = true, ["\xe2\x80\x94"] = true, ["\xe2\x80\x95"] = true,
    ["\xe2\x80\x98"] = true, ["\xe2\x80\x99"] = true, ["\xe2\x80\x9a"] = true,
    ["\xe2\x80\x9b"] = true, ["\xe2\x80\x9c"] = true, ["\xe2\x80\x9d"] = true,
    ["\xe2\x80\x9e"] = true, ["\xe2\x80\x9f"] = true, ["\xe2\x80\xa2"] = true,
    ["\xe2\x80\xa6"] = true, ["\xe2\x80\xa7"] = true, ["\xe2\x84\xa2"] = true,
    -- CJK Punctuation
    ["\xe3\x80\x80"] = true, ["\xe3\x80\x81"] = true, ["\xe3\x80\x82"] = true, ["\xe3\x80\x83"] = true,
    ["\xe3\x80\x88"] = true, ["\xe3\x80\x89"] = true, ["\xe3\x80\x8a"] = true, ["\xe3\x80\x8b"] = true,
    ["\xe3\x80\x8c"] = true, ["\xe3\x80\x8d"] = true, ["\xe3\x80\x8e"] = true, ["\xe3\x80\x8f"] = true,
    ["\xe3\x80\x90"] = true, ["\xe3\x80\x91"] = true, ["\xe3\x80\x94"] = true, ["\xe3\x80\x95"] = true,
}

local function is_word_char(char)
    if #char == 1 then
        return char:match("[a-zA-Z0-9]") ~= nil
    end
    return not UNICODE_PUNCTUATION[char]
end

-- Groups text characters into orthographic syllables (grapheme clusters)
-- This keeps combining vowels/matras/viramas bound to their consonant bases
local function get_grapheme_clusters(s)
    local chars = utf8_chars(s)
    local clusters = {}
    local i = 1
    local len = #chars

    local function get_cp(idx)
        if idx > len then return nil end
        return utf8_codepoint(chars[idx])
    end

    local function is_combining_vowel_or_modifier(cp)
        if not cp then return false end
        -- Latin combining marks
        if cp >= 0x0300 and cp <= 0x036f then return true end
        -- Devanagari combining marks
        if (cp >= 0x0900 and cp <= 0x0903) or cp == 0x093c or (cp >= 0x093e and cp <= 0x094c) or (cp >= 0x0951 and cp <= 0x0957) or (cp >= 0x0962 and cp <= 0x0963) then
            return true
        end
        -- Other Indic combining vowel/modifier signs
        local block = math.floor(cp / 128) * 128
        if block >= 0x0980 and block <= 0x0dff then
            local offset = cp - block
            if (offset >= 0x01 and offset <= 0x03) or offset == 0x3c or (offset >= 0x3e and offset <= 0x4c) or (offset >= 0x51 and offset <= 0x57) or (offset >= 0x62 and offset <= 0x63) then
                return true
            end
        end
        return false
    end

    local function is_consonant(cp)
        if not cp then return false end
        -- Devanagari consonants
        if cp >= 0x0915 and cp <= 0x0939 then return true end
        -- Other Indic consonants
        local block = math.floor(cp / 128) * 128
        if block >= 0x0980 and block <= 0x0dff then
            local offset = cp - block
            if offset >= 0x15 and offset <= 0x39 then return true end
        end
        return false
    end

    local function is_virama(cp)
        if not cp then return false end
        if cp == 0x094d then return true end -- Devanagari
        local block = math.floor(cp / 128) * 128
        if block >= 0x0980 and block <= 0x0dff then
            return (cp - block) == 0x4d
        end
        return false
    end

    while i <= len do
        local cluster = { chars[i] }
        local cp = get_cp(i)
        i = i + 1

        -- Conjunct handling: consonant + virama + consonant
        while is_consonant(cp) and is_virama(get_cp(i)) do
            table.insert(cluster, chars[i]) -- Append virama
            i = i + 1
            local next_cp = get_cp(i)
            if next_cp then
                table.insert(cluster, chars[i]) -- Append consonant
                cp = next_cp
                i = i + 1
            else
                break
            end
        end

        -- Append any combining vowel signs / modifiers
        while is_combining_vowel_or_modifier(get_cp(i)) do
            table.insert(cluster, chars[i])
            i = i + 1
        end

        table.insert(clusters, table.concat(cluster))
    end

    return clusters
end

-- Checks if a word is in a styleable script for Bionic bolding (Latin, Cyrillic, Greek, Indic)
-- Cursive RTL (Arabic) or non-spaced logographic (CJK) scripts are bypassed.
local function is_styleable_script(word)
    local chars = utf8_chars(word)
    for _, char in ipairs(chars) do
        local cp = utf8_codepoint(char)
        local is_latin = (cp >= 0x41 and cp <= 0x5a) or (cp >= 0x61 and cp <= 0x7a) or
                         (cp >= 0xc0 and cp <= 0xff) or (cp >= 0x0100 and cp <= 0x024f) or
                         (cp >= 0x1e00 and cp <= 0x1eff)
        local is_cyrillic = (cp >= 0x0400 and cp <= 0x052f)
        local is_greek = (cp >= 0x0370 and cp <= 0x03ff)
        local is_indic = (cp >= 0x0900 and cp <= 0x0dff)
        if not (is_latin or is_cyrillic or is_greek or is_indic) then
            return false
        end
    end
    return true
end

local function bold_word(word)
    if not is_styleable_script(word) then
        return word
    end
    local clusters = get_grapheme_clusters(word)
    local len = #clusters
    if len == 0 then
        return ""
    end
    local midpoint = (len == 1 or len == 3) and 1 or math.ceil(len / 2)
    local first_half = table.concat(clusters, "", 1, midpoint)
    local second_half = table.concat(clusters, "", midpoint + 1)
    return "<b>" .. first_half .. "</b>" .. second_half
end

local function orp_word(word)
    if not is_styleable_script(word) then
        return word
    end
    local clusters = get_grapheme_clusters(word)
    local len = #clusters
    if len == 0 then
        return ""
    end

    -- Always bold the first grapheme cluster (first letter for Latin,
    -- first complete syllable/compound consonant for Devanagari/Indic)
    local first = clusters[1]
    local rest = table.concat(clusters, "", 2)
    return "<b>" .. first .. "</b>" .. rest
end

local function inject_guided_separator(separator)
    local replaced, count = separator:gsub("[ \t]+", " " .. GUIDE_DOT_ENTITY .. " ", 1)
    if count > 0 then
        return replaced
    end
    return separator
end

local function tokenize_text(text)
    local chars = utf8_chars(text)
    local tokens = {}
    local current_token = {}
    local current_is_word = nil

    for _, char in ipairs(chars) do
        local is_word = is_word_char(char)
        if current_is_word == nil then
            current_is_word = is_word
            table.insert(current_token, char)
        elseif current_is_word == is_word then
            table.insert(current_token, char)
        else
            table.insert(tokens, {
                is_word = current_is_word,
                text = table.concat(current_token)
            })
            current_is_word = is_word
            current_token = { char }
        end
    end

    if #current_token > 0 then
        table.insert(tokens, {
            is_word = current_is_word,
            text = table.concat(current_token)
        })
    end

    return tokens
end

local function transform_text_part(part, state)
    if part == "" then
        return part
    end

    local tokens = tokenize_text(part)
    if #tokens == 0 then
        return part
    end

    local pieces = {}
    for i, token in ipairs(tokens) do
        if token.is_word then
            local styled = token.text
            if state.bionic then
                styled = bold_word(token.text)
            elseif state.orp then
                styled = orp_word(token.text)
            end
            pieces[#pieces + 1] = styled
        else
            local separator = token.text
            -- Guided spacer dot is available for everyone (flanked by words)
            local has_flanking_words = false
            if state.guided and i > 1 and i < #tokens then
                local prev_token = tokens[i - 1]
                local next_token = tokens[i + 1]
                if prev_token.is_word and next_token.is_word then
                    has_flanking_words = true
                end
            end
            
            if has_flanking_words then
                separator = inject_guided_separator(separator)
            end
            pieces[#pieces + 1] = separator
        end
    end

    return table.concat(pieces)
end

local function transform_text_node(text, state)
    local pieces = {}
    local index = 1

    while true do
        local s, e, entity = text:find("(&[#%a][%w]*;)", index)
        if not s then
            pieces[#pieces + 1] = transform_text_part(text:sub(index), state)
            break
        end
        if s > index then
            pieces[#pieces + 1] = transform_text_part(text:sub(index, s - 1), state)
        end
        pieces[#pieces + 1] = entity
        index = e + 1
    end

    return table.concat(pieces)
end

local function get_tag_name(tag)
    local closing, name = tag:match("^<%s*(/?)%s*([%w:_-]+)")
    if not name then
        return nil, false
    end
    return name:lower(), closing == "/"
end

local function is_self_closing_tag(tag)
    if tag:match("^<%s*!") or tag:match("^<%s*%?") then
        return true
    end
    return tag:match("/%s*>$") ~= nil
end

local function count_word_tokens(text, max_count)
    local tokens = tokenize_text(text)
    local count = 0
    for _, token in ipairs(tokens) do
        if token.is_word then
            count = count + 1
            if max_count and count >= max_count then
                break
            end
        end
    end
    return count
end

local function strip_protected_blocks(text)
    local stripped = text
    for tag_name in pairs(PROTECTED_TEXT_TAGS) do
        stripped = stripped:gsub("<" .. tag_name .. "[^>]*>[%z\1-\255]-</" .. tag_name .. "%s*>", " ")
    end
    return stripped
end

local function is_visual_only_body(body_content)
    local lower = body_content:lower()
    local has_visual_markup = lower:find("<svg[%s>/]")
        or lower:find("<img[%s>/]")
        or lower:find("<image[%s>/]")
        or lower:find("<object[%s>/]")
    if not has_visual_markup then
        return false
    end

    local stripped = strip_protected_blocks(lower)
    stripped = stripped:gsub("<[^>]+>", " ")
    stripped = stripped:gsub("&#?[%a%d]+;", " ")
    return count_word_tokens(stripped, 3) < 3
end

local function transform_body_content(body_content, state)
    local pieces = {}
    local index = 1
    local protected_depth = 0

    while true do
        local tag_start, tag_end, tag = body_content:find("(<[^>]+>)", index)
        if not tag_start then
            local tail = body_content:sub(index)
            pieces[#pieces + 1] = protected_depth > 0 and tail or transform_text_node(tail, state)
            break
        end

        if tag_start > index then
            local text = body_content:sub(index, tag_start - 1)
            pieces[#pieces + 1] = protected_depth > 0 and text or transform_text_node(text, state)
        end

        pieces[#pieces + 1] = tag

        local tag_name, is_closing = get_tag_name(tag)
        if tag_name and PROTECTED_TEXT_TAGS[tag_name] then
            if is_closing then
                protected_depth = math.max(0, protected_depth - 1)
            elseif not is_self_closing_tag(tag) then
                protected_depth = protected_depth + 1
            end
        end

        index = tag_end + 1
    end

    return table.concat(pieces)
end

-- Case-insensitive Body Extractor
local function extract_body(html)
    local body_start, body_end = html:find("<[Bb][Oo][Dd][Yy][^>]*>")
    if not body_start then
        return nil
    end
    local close_start, close_end = html:find("</[Bb][Oo][Dd][Yy]%s*>", body_end + 1)
    if not close_start then
        return nil
    end
    return body_start, body_end, close_start, close_end
end

local function transform_html_document(html, state)
    if not has_active_feature(state) then
        return html
    end

    local body_start, body_end, close_start, close_end = extract_body(html)
    if not body_start then
        return html
    end

    local body_content = html:sub(body_end + 1, close_start - 1)
    if is_visual_only_body(body_content) then
        return html
    end

    local transformed = transform_body_content(body_content, state)
    return html:sub(1, body_end) .. transformed .. html:sub(close_start)
end

local function transform_xhtml_file(input_file, output_file, state)
    local input = io.open(input_file, "rb")
    if not input then
        return nil, "unable to read source"
    end
    local content = input:read("*all")
    input:close()

    local temp = output_file .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write output"
    end
    out:write(transform_html_document(content, state))
    out:close()

    os.remove(output_file)
    if not os.rename(temp, output_file) then
        os.remove(temp)
        return nil, "unable to finalize output"
    end
    return true
end

local function transform_epub_file(input_file, output_file, state)
    local ok_archive, Archive = pcall(require, "ffi/archiver")
    if not ok_archive or not Archive then
        return nil, "archiver unavailable"
    end

    local temp = output_file .. ".tmp"
    os.remove(temp)

    local reader = Archive.Reader:new()
    if not reader:open(input_file) then
        return nil, reader.err or "unable to open source epub"
    end
    local writer = Archive.Writer:new()
    if not writer:open(temp, "zip") then
        reader:close()
        return nil, writer.err or "unable to open output epub"
    end

    if not writer:setZipCompression("store") then
        reader:close()
        writer:close()
        os.remove(temp)
        return nil, writer.err or "unable to set store compression"
    end
    if not writer:addFileFromMemory("mimetype", "application/epub+zip") then
        reader:close()
        writer:close()
        os.remove(temp)
        return nil, writer.err or "unable to write mimetype"
    end
    if not writer:setZipCompression("deflate") then
        reader:close()
        writer:close()
        os.remove(temp)
        return nil, writer.err or "unable to set deflate compression"
    end

    local ok = true
    local err = nil
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path == "mimetype" then
                goto continue
            end
            local content = reader:extractToMemory(entry.index)
            if content == nil then
                ok = false
                err = reader.err or ("unable to read " .. entry.path)
                break
            end
            local lower = entry.path:lower()
            local filename = lower:match("([^/]+)$") or lower
            if is_xhtml_path(lower) and not TOC_FILENAMES[filename] then
                content = transform_html_document(content, state)
            end
            if not writer:addFileFromMemory(entry.path, content) then
                ok = false
                err = writer.err or ("unable to write " .. entry.path)
                break
            end
            
            -- Memory cleanup after each file
            content = nil
            collectgarbage("step")
        end
        ::continue::
    end
    reader:close()
    writer:close()

    if not ok then
        os.remove(temp)
        return nil, err
    end

    os.remove(output_file)
    if not os.rename(temp, output_file) then
        os.remove(temp)
        return nil, "unable to finalize output epub"
    end
    return true
end

local function validate_epub_file(filepath)
    local ok_archive, Archive = pcall(require, "ffi/archiver")
    if not ok_archive or not Archive then
        return nil, "archiver unavailable"
    end
    local reader = Archive.Reader:new()
    if not reader:open(filepath) then
        return nil, reader.err or "unable to open generated epub"
    end
    local has_mimetype, has_container = false, false
    local mimetype_content = nil
    for entry in reader:iterate() do
        if entry.mode == "file" then
            if entry.path == "mimetype" then
                has_mimetype = true
                mimetype_content = reader:extractToMemory(entry.index)
            elseif entry.path == "META-INF/container.xml" then
                has_container = true
            end
        end
    end
    reader:close()
    if not has_mimetype then
        return nil, "missing mimetype"
    end
    if mimetype_content ~= "application/epub+zip" then
        return nil, "invalid mimetype content"
    end
    if not has_container then
        return nil, "missing container.xml"
    end
    return true
end

local function transform_markdown_file(input_file, output_file, state)
    local input = io.open(input_file, "rb")
    if not input then
        return nil, "unable to read source"
    end
    local content = input:read("*all")
    input:close()

    local ext = get_extension(input_file)
    local transformed
    if ext == "txt" then
        local body = transform_body_content(content, state)
        transformed = "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n" ..
                      "<style>body { white-space: pre-wrap; font-family: sans-serif; }</style>\n" ..
                      "</head>\n<body>\n" .. body .. "\n</body>\n</html>"
    else
        transformed = transform_body_content(content, state)
    end

    local temp = output_file .. ".tmp"
    local out = io.open(temp, "wb")
    if not out then
        return nil, "unable to write output"
    end
    out:write(transformed)
    out:close()

    os.remove(output_file)
    if not os.rename(temp, output_file) then
        os.remove(temp)
        return nil, "unable to finalize output"
    end
    return true
end

local function apply_feature_state_inplace(file, new_state)
    local state = normalize_feature_state(new_state)
    local backup = get_backup_path(file)
    local state_path = get_state_path(file)
    local had_backup = file_exists(backup)
    local rollback = file .. ".intellireading.rollback.tmp"
    os.remove(rollback)
    copy_file(file, rollback)

    local function restore_previous_file()
        if file_exists(rollback) then
            copy_file(rollback, file)
        end
        os.remove(rollback)
    end

    if not has_active_feature(state) then
        if had_backup then
            local ok_copy, err_copy = copy_file(backup, file)
            if not ok_copy then
                restore_previous_file()
                return nil, err_copy
            end
            os.remove(backup)
        end
        os.remove(state_path)
        os.remove(rollback)
        unregister_modified_book(file)
        return true
    end

    if not had_backup then
        local sdr_dir = get_sdr_path(file)
        if not dir_exists(sdr_dir) then
            lfs.mkdir(sdr_dir)
        end
        local ok_copy, err_copy = copy_file(file, backup)
        if not ok_copy then
            restore_previous_file()
            return nil, err_copy
        end
    end

    local ok_transform, err_transform
    if is_epub_path(file) then
        ok_transform, err_transform = transform_epub_file(backup, file, state)
        if ok_transform then
            local valid, valid_err = validate_epub_file(file)
            if not valid then
                ok_transform = nil
                err_transform = valid_err
            end
        end
    elseif is_xhtml_path(file) then
        ok_transform, err_transform = transform_xhtml_file(backup, file, state)
    elseif is_markdown_path(file) then
        ok_transform, err_transform = transform_markdown_file(backup, file, state)
    end

    if not ok_transform then
        restore_previous_file()
        if not had_backup and not file_exists(state_path) then
            os.remove(backup)
        end
        return nil, err_transform or "transform failed"
    end

    local ok_state, err_state = write_feature_state(file, state)
    if not ok_state then
        restore_previous_file()
        if not had_backup then
            os.remove(backup)
        end
        return nil, err_state or "unable to persist state"
    end

    os.remove(rollback)
    register_modified_book(file)
    return true
end

-- Global restore routine
local function restore_all_books()
    local settings = LuaSettings:open(settings_path)
    local books = settings:readSetting("modified_books") or {}
    for file_path, _ in pairs(books) do
        local backup = get_backup_path(file_path)
        local state_path = get_state_path(file_path)
        if file_exists(backup) then
            copy_file(backup, file_path)
            os.remove(backup)
        end
        os.remove(state_path)
    end
    settings:saveSetting("modified_books", {})
    settings:flush()
end

local function clamp(value, low, high)
    if value < low then
        return low
    end
    if value > high then
        return high
    end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

local function capture_progress(ui)
    if not ui or not ui.document then
        return nil
    end

    local document = ui.document
    local snapshot = {
        current_page = document.getCurrentPage and document:getCurrentPage() or nil,
        page_count = document.getPageCount and document:getPageCount() or nil,
    }

    if ui.rolling then
        snapshot.mode = "rolling"
        snapshot.view_mode = ui.rolling.view and ui.rolling.view.view_mode or nil
        snapshot.current_pos = document.getCurrentPos and document:getCurrentPos() or nil
        snapshot.doc_height = document.info and document.info.doc_height or nil
    elseif ui.paging then
        snapshot.mode = "paging"
        snapshot.location = ui.paging.getBookLocation and ui.paging:getBookLocation() or nil
    end

    return snapshot
end

local function restore_progress(ui, snapshot)
    if not ui or not snapshot or not ui.document then
        return
    end

    local document = ui.document
    local old_pages = tonumber(snapshot.page_count) or 0
    local new_pages = tonumber(document:getPageCount()) or 0
    local current_page = tonumber(snapshot.current_page) or 1

    if ui.rolling then
        if snapshot.view_mode == "page" then
            if new_pages <= 0 then
                return
            end
            local new_page
            if old_pages > 1 then
                local ratio = (current_page - 1) / (old_pages - 1)
                new_page = round(ratio * math.max(new_pages - 1, 0)) + 1
            else
                new_page = current_page
            end
            ui.rolling:onGotoPage(clamp(new_page, 1, new_pages))
            return
        end

        local old_height = tonumber(snapshot.doc_height) or 0
        local old_pos = tonumber(snapshot.current_pos) or 0
        local new_height = document.info and tonumber(document.info.doc_height) or 0
        if old_height > 0 and new_height > 0 then
            local new_pos = round((old_pos / old_height) * new_height)
            ui.rolling:_gotoPos(new_pos)
            ui.rolling.xpointer = document:getXPointer()
        elseif new_pages > 0 then
            local new_page
            if old_pages > 1 then
                local ratio = (current_page - 1) / (old_pages - 1)
                new_page = round(ratio * math.max(new_pages - 1, 0)) + 1
            else
                new_page = current_page
            end
            ui.rolling:onGotoPage(clamp(new_page, 1, new_pages))
        end
        return
    end

    if ui.paging then
        if snapshot.location and old_pages > 0 and new_pages == old_pages then
            ui.paging:onRestoreBookLocation(snapshot.location)
            return
        end
        if new_pages <= 0 then
            return
        end
        local new_page
        if old_pages > 1 then
            local ratio = (current_page - 1) / (old_pages - 1)
            new_page = round(ratio * math.max(new_pages - 1, 0)) + 1
        else
            new_page = current_page
        end
        ui.paging:onGotoPage(clamp(new_page, 1, new_pages))
    end
end

local function get_feature_name(feature)
    if feature == FEATURE_GUIDED then
        return _("Guided dots")
    elseif feature == FEATURE_ORP then
        return _("First letter focus")
    end
    return _("Bionic reading")
end

local function get_toggle_success_message(feature, enabled)
    if feature == FEATURE_GUIDED then
        return enabled and _("Guided dots enabled.") or _("Guided dots disabled.")
    elseif feature == FEATURE_ORP then
        return enabled and _("First letter focus enabled.") or _("First letter focus disabled.")
    end
    return enabled and _("Bionic reading enabled.") or _("Bionic reading disabled.")
end

local function get_toggle_failure_message(feature)
    if feature == FEATURE_GUIDED then
        return _("Guided dots failed.")
    elseif feature == FEATURE_ORP then
        return _("First letter focus failed.")
    end
    return _("Bionic reading failed.")
end

local on_toggle_feature

local function make_feature_menu_item(ui, feature)
    local key
    if feature == FEATURE_GUIDED then
        key = GUIDED_MENU_KEY
    elseif feature == FEATURE_ORP then
        key = ORP_MENU_KEY
    else
        key = BIONIC_MENU_KEY
    end
    return {
        id = key,
        text = get_feature_name(feature),
        checked_func = function()
            local file = ui and ui.document and ui.document.file
            if feature == FEATURE_GUIDED then
                return is_guided_active_for_file(file)
            elseif feature == FEATURE_ORP then
                return is_orp_active_for_file(file)
            end
            return is_bionic_active_for_file(file)
        end,
        callback = function()
            on_toggle_feature(ui, feature)
        end,
    }
end

local function reload_with_progress(ui, feature, enabled, state_change_func, success_message)
    local snapshot = capture_progress(ui)
    local reload_result = { ok = true, err = nil }

    ui:reloadDocument(
        function(file, provider)
            local ok, err = state_change_func()
            reload_result.ok = ok and true or false
            reload_result.err = err
        end,
        true, -- seamless
        function(new_ui)
            if snapshot then
                restore_progress(new_ui, snapshot)
            end
            if reload_result.ok then
                UIManager:show(InfoMessage:new{
                    text = success_message or get_toggle_success_message(feature, enabled),
                    timeout = 2,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = feature and get_toggle_failure_message(feature) or _("Failed to restore books."),
                    timeout = 2,
                })
            end
        end
    )
end

on_toggle_feature = function(ui, feature)
    if not ui or not ui.document or not is_supported_file(ui.document.file) then
        UIManager:show(InfoMessage:new{
            text = _("Intelli reading supports EPUB/HTML/XHTML files only."),
            timeout = 2,
        })
        return
    end

    local file = ui.document.file
    local state = read_feature_state(file)
    local new_state = normalize_feature_state(state)
    new_state[feature] = not new_state[feature]

    -- Mutual exclusion: Bionic and First Letter Focus cannot be active at the same time
    if feature == FEATURE_BIONIC and new_state.bionic then
        new_state.orp = false
    elseif feature == FEATURE_ORP and new_state.orp then
        new_state.bionic = false
    end

    local enabled = new_state[feature]

    reload_with_progress(ui, feature, enabled, function()
        return apply_feature_state_inplace(file, new_state)
    end)
end

local function insert_menu_key_before(order, before_key, new_key)
    for _, key in ipairs(order) do
        if key == new_key then
            return true
        end
    end

    for index, key in ipairs(order) do
        if key == before_key then
            table.insert(order, index, new_key)
            return true
        end
    end

    return false
end

local function patch_reader_menu_order()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or not order or not order.typeset then
        return false
    end

    local inserted_guided = insert_menu_key_before(order.typeset, "typography", GUIDED_MENU_KEY)
    local inserted_bionic = insert_menu_key_before(order.typeset, "typography", BIONIC_MENU_KEY)
    local inserted_orp = insert_menu_key_before(order.typeset, "typography", ORP_MENU_KEY)
    local inserted_restore = insert_menu_key_before(order.typeset, "typography", RESTORE_MENU_KEY)
    return inserted_guided or inserted_bionic or inserted_orp or inserted_restore
end

local function patch_readertypography_menu()
    local ok, ReaderTypography = pcall(require, "apps/reader/modules/readertypography")
    if not ok or not ReaderTypography or type(ReaderTypography.addToMainMenu) ~= "function" then
        return false
    end
    if ReaderTypography[PATCH_FLAG] then
        return true
    end

    local orig_add_to_main_menu = ReaderTypography.addToMainMenu
    ReaderTypography.addToMainMenu = function(self, menu_items)
        orig_add_to_main_menu(self, menu_items)
        local guided_item = make_feature_menu_item(self and self.ui, FEATURE_GUIDED)
        local bionic_item = make_feature_menu_item(self and self.ui, FEATURE_BIONIC)
        local orp_item = make_feature_menu_item(self and self.ui, FEATURE_ORP)
        local restore_item = {
            id = RESTORE_MENU_KEY,
            text = _("Restore all books"),
            checked_func = function() return false end,
            callback = function()
                local ui = self and self.ui
                local current_file = ui and ui.document and ui.document.file
                local was_active = current_file and (is_bionic_active_for_file(current_file) or is_guided_active_for_file(current_file) or is_orp_active_for_file(current_file))

                if was_active and ui then
                    reload_with_progress(ui, nil, nil, function()
                        restore_all_books()
                        return true
                    end, _("All books restored to original state."))
                else
                    restore_all_books()
                    if ui then
                        ui:handleEvent(Event:new("CloseReaderMenu"))
                        ui:handleEvent(Event:new("CloseConfigMenu"))
                    end
                    UIManager:show(InfoMessage:new{
                        text = _("All books restored to original state."),
                        timeout = 2,
                    })
                end
            end,
        }
        guided_item.sorting_hint = "typeset"
        bionic_item.sorting_hint = "typeset"
        orp_item.sorting_hint = "typeset"
        restore_item.sorting_hint = "typeset"
        menu_items[GUIDED_MENU_KEY] = guided_item
        menu_items[BIONIC_MENU_KEY] = bionic_item
        menu_items[ORP_MENU_KEY] = orp_item
        menu_items[RESTORE_MENU_KEY] = restore_item
    end

    ReaderTypography[PATCH_FLAG] = true
    return true
end

local function remove_menu_item_by_id(menu, item_id)
    if not menu then
        return nil
    end
    for i = #menu, 1, -1 do
        local item = menu[i]
        if type(item) == "table" and item.id == item_id then
            return table.remove(menu, i)
        end
    end
    return nil
end

local function insert_menu_item_before_id(menu, before_id, item)
    if not menu or not item then
        return false
    end
    for i = 1, #menu do
        local existing = menu[i]
        if type(existing) == "table" and existing.id == before_id then
            table.insert(menu, i, item)
            return true
        end
    end
    return false
end

local function find_menu_containing_id(tabs, item_id)
    if not tabs then
        return nil
    end
    for _, menu in ipairs(tabs) do
        if type(menu) == "table" then
            for __, item in ipairs(menu) do
                if type(item) == "table" and item.id == item_id then
                    return menu
                end
            end
        end
    end
    return nil
end

local function patch_readermenu_position()
    local ok, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if not ok or not ReaderMenu or type(ReaderMenu.setUpdateItemTable) ~= "function" then
        return false
    end
    if ReaderMenu[READERMENU_PATCH_FLAG] then
        return true
    end

    local orig_set_update_item_table = ReaderMenu.setUpdateItemTable
    ReaderMenu.setUpdateItemTable = function(self, ...)
        orig_set_update_item_table(self, ...)

        local tabs = self and self.tab_item_table
        if not tabs then
            return
        end

        local guided_item
        local bionic_item
        local orp_item
        local restore_item
        for _, menu in ipairs(tabs) do
            if type(menu) == "table" then
                guided_item = guided_item or remove_menu_item_by_id(menu, GUIDED_MENU_KEY)
                bionic_item = bionic_item or remove_menu_item_by_id(menu, BIONIC_MENU_KEY)
                orp_item = orp_item or remove_menu_item_by_id(menu, ORP_MENU_KEY)
                restore_item = restore_item or remove_menu_item_by_id(menu, RESTORE_MENU_KEY)
            end
        end

        local target_menu = find_menu_containing_id(tabs, "typography")
        if type(target_menu) ~= "table" then
            return
        end

        if guided_item then
            guided_item.separator = true
            if not insert_menu_item_before_id(target_menu, "typography", guided_item) then
                table.insert(target_menu, guided_item)
            end
        end
        if bionic_item then
            bionic_item.separator = false
            if not insert_menu_item_before_id(target_menu, "typography", bionic_item) then
                table.insert(target_menu, bionic_item)
            end
        end
        if orp_item then
            orp_item.separator = false
            if not insert_menu_item_before_id(target_menu, "typography", orp_item) then
                table.insert(target_menu, orp_item)
            end
        end
        if restore_item then
            restore_item.separator = false
            if not insert_menu_item_before_id(target_menu, "typography", restore_item) then
                table.insert(target_menu, restore_item)
            end
        end
    end

    ReaderMenu[READERMENU_PATCH_FLAG] = true
    return true
end

-- Unicode-aware check for word selections
local function is_non_space_text(text)
    if not text or text == "" then
        return false
    end
    local chars = utf8_chars(text)
    for _, char in ipairs(chars) do
        if char == "-" then
            -- Allow '-' as a separator/joiner inside word lookup boundaries
        elseif not is_word_char(char) then
            return false
        end
    end
    return true
end

local function expand_selection_across_non_spaces(document, selected_text)
    if not document or not selected_text or not selected_text.pos0 or not selected_text.pos1 then
        return nil
    end
    if type(document.getPrevVisibleChar) ~= "function"
        or type(document.getNextVisibleChar) ~= "function"
        or type(document.getTextFromXPointers) ~= "function" then
        return nil
    end

    local pos0 = selected_text.pos0
    local pos1 = selected_text.pos1
    local changed = false

    for _ = 1, 128 do
        local prev = document:getPrevVisibleChar(pos0)
        if not prev then
            break
        end
        local candidate = document:getTextFromXPointers(prev, pos1, true)
        if not is_non_space_text(util.cleanupSelectedText(candidate or "")) then
            break
        end
        pos0 = prev
        changed = true
    end

    for _ = 1, 128 do
        local nextp = document:getNextVisibleChar(pos1)
        if not nextp then
            break
        end
        local candidate = document:getTextFromXPointers(pos0, nextp, true)
        if not is_non_space_text(util.cleanupSelectedText(candidate or "")) then
            break
        end
        pos1 = nextp
        changed = true
    end

    if not changed then
        return nil
    end

    local new_text = document:getTextFromXPointers(pos0, pos1, true)
    if not new_text or new_text == "" then
        return nil
    end

    local sboxes = type(document.getScreenBoxesFromPositions) == "function"
        and document:getScreenBoxesFromPositions(pos0, pos1, true)
        or nil

    return {
        text = util.cleanupSelectedText(new_text),
        pos0 = pos0,
        pos1 = pos1,
        sboxes = (sboxes and #sboxes > 0) and sboxes or selected_text.sboxes,
        pboxes = selected_text.pboxes,
    }
end

local function patch_readerhighlight_lookup()
    local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if not ok or not ReaderHighlight or type(ReaderHighlight.onHold) ~= "function" then
        return false
    end
    if ReaderHighlight[LOOKUP_PATCH_FLAG] then
        return true
    end

    local orig_on_hold = ReaderHighlight.onHold
    ReaderHighlight.onHold = function(self, arg, ges)
        local handled = orig_on_hold(self, arg, ges)
        local ui = self and self.ui
        local doc = ui and ui.document

        if handled and self and self.is_word_selection and self.selected_text
            and ui and (is_bionic_active_for_file(doc and doc.file) or is_orp_active_for_file(doc and doc.file)) then
            local expanded = expand_selection_across_non_spaces(doc, self.selected_text)
            if expanded then
                self.selected_text = expanded
                if self.ui and self.ui.paging and self.hold_pos and self.selected_text.sboxes then
                    self.view.highlight.temp[self.hold_pos.page] = self.selected_text.sboxes
                    UIManager:setDirty(self.dialog, "ui")
                elseif self.selected_text.sboxes then
                    UIManager:setDirty(self.dialog, "ui", Geom.boundingBox(self.selected_text.sboxes))
                else
                    UIManager:setDirty(self.dialog, "ui")
                end
            end
        end
        return handled
    end

    ReaderHighlight[LOOKUP_PATCH_FLAG] = true
    return true
end

local function apply_patch()
    patch_readertypography_menu()
    patch_readermenu_position()
    patch_readerhighlight_lookup()
end

apply_patch()

userpatch.registerPatchPluginFunc("perceptionexpander", function()
    apply_patch()
end)
