local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.opt.runtimepath:prepend(root .. "/editors/vim")

vim.filetype.add({ extension = { eon = "eon" } })

local parser = root .. "/tree-sitter-eon/eon.so"
vim.treesitter.language.add("eon", { path = parser })

local query_path = root .. "/tree-sitter-eon/queries/highlights.scm"
local query = table.concat(vim.fn.readfile(query_path), "\n")
vim.treesitter.query.set("eon", "highlights", query)
