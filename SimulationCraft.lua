--[[--------------------------------------------------------------------
    Copyright (C) 2014 Johnny C. Lam.
    See the file LICENSE.txt for copying permission.
--]]--------------------------------------------------------------------

local OVALE, Ovale = ...
local OvaleSimulationCraft = Ovale:NewModule("OvaleSimulationCraft")
Ovale.OvaleSimulationCraft = OvaleSimulationCraft

--<private-static-properties>
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local L = Ovale.L
local OvaleOptions = Ovale.OvaleOptions
local OvalePool = Ovale.OvalePool

-- Forward declarations for module dependencies.
local OvaleAST = nil
local OvaleData = nil
local OvaleLexer = nil
local OvalePower = nil

local format = string.format
local gmatch = string.gmatch
local gsub = string.gsub
local ipairs = ipairs
local pairs = pairs
local rawset = rawset
local strfind = string.find
local strlen = string.len
local strlower = string.lower
local strmatch = string.match
local strsub = string.sub
local strupper = string.upper
local tconcat = table.concat
local tinsert = table.insert
local tonumber = tonumber
local tostring = tostring
local tsort = table.sort
local type = type
local wipe = table.wipe
local yield = coroutine.yield
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

-- Keywords for SimulationCraft action lists.
local KEYWORD = {}

local MODIFIER_KEYWORD = {
	["ammo_type"] = true,
	["chain"] = true,
	["choose"] = true,
	["cooldown"] = true,
	["cooldown_stddev"] = true,
	["cycle_targets"] = true,
	["damage"] = true,
	["early_chain_if"] = true,
	["extra_amount"] = true,
	["five_stacks"] = true,
	["for_next"] = true,
	["if"] = true,
	["interrupt"] = true,
	["interrupt_if"] = true,
	["lethal"] = true,
	["line_cd"] = true,
	["max_cycle_targets"] = true,
	["moving"] = true,
	["name"] = true,
	["sec"] = true,
	["slot"] = true,
	["sync"] = true,
	["sync_weapons"] = true,
	["target"] = true,
	["travel_speed"] = true,
	["type"] = true,
	["wait"] = true,
	["wait_on_ready"] = true,
	["weapon"] = true,
}

local FUNCTION_KEYWORD = {
	["ceil"] = true,
	["floor"] = true,
}

local SPECIAL_ACTION = {
	["apply_poison"] = true,
	["auto_attack"] = true,
	["call_action_list"] = true,
	["cancel_buff"] = true,
	["cancel_metamorphosis"] = true,
	["exotic_munitions"] = true,
	["flask"] = true,
	["food"] = true,
	["health_stone"] = true,
	["pool_resource"] = true,
	["potion"] = true,
	["run_action_list"] = true,
	["snapshot_stats"] = true,
	["stance"] = true,
	["start_moving"] = true,
	["stealth"] = true,
	["stop_moving"] = true,
	["swap_action_list"] = true,
	["use_item"] = true,
	["wait"] = true,
}

local RUNE_OPERAND = {
	["blood"] = "blood",
	["death"] = "death",
	["frost"] = "frost",
	["unholy"] = "unholy",
	["rune.blood"] = "blood",
	["rune.death"] = "death",
	["rune.frost"] = "frost",
	["rune.unholy"] = "unholy",
}

do
	-- All expression keywords are keywords.
	for keyword, value in pairs(MODIFIER_KEYWORD) do
		KEYWORD[keyword] = value
	end
	-- All function keywords are keywords.
	for keyword, value in pairs(FUNCTION_KEYWORD) do
		KEYWORD[keyword] = value
	end
	-- All special actions are keywords.
	for keyword, value in pairs(SPECIAL_ACTION) do
		KEYWORD[keyword] = value
	end
end

-- Table of pattern/tokenizer pairs for SimulationCraft action lists.
local MATCHES = nil

-- Unary and binary operators with precedence.
local UNARY_OPERATOR = {
	["!"]  = { "logical", 15 },
	["-"]  = { "arithmetic", 50 },
}
local BINARY_OPERATOR = {
	-- logical
	["|"]  = { "logical", 5, "associative" },
	["^"]  = { "logical", 8, "associative" },
	["&"]  = { "logical", 10, "associative" },
	-- comparison
	["!="] = { "compare", 20 },
	["<"]  = { "compare", 20 },
	["<="] = { "compare", 20 },
	["="]  = { "compare", 20 },
	[">"]  = { "compare", 20 },
	[">="] = { "compare", 20 },
	["~"]  = { "compare", 20 },
	["!~"] = { "compare", 20 },
	-- addition, subtraction
	["+"]  = { "arithmetic", 30, "associative" },
	["-"]  = { "arithmetic", 30 },
	-- multiplication, division, modulus
	["%"]  = { "arithmetic", 40 },
	["*"]  = { "arithmetic", 40, "associative" },
}

-- INDENT[k] is a string of k concatenated tabs.
local INDENT = {}
do
	INDENT[0] = ""
	local metatable = {
		__index = function(tbl, key)
			key = tonumber(key)
			if key > 0 then
				local s = tbl[key - 1] .. "\t"
				rawset(tbl, key, s)
				return s
			end
			return INDENT[0]
		end,
	}
	setmetatable(INDENT, metatable)
end

local EMIT_DISAMBIGUATION = {}
local EMIT_EXTRA_PARAMETERS = {}
local OPERAND_TOKEN_PATTERN = "[^.]+"

local TOTEM_TYPE = {
	["prismatic_crystal"] = "crystal",	-- XXX
	["capacitor_totem"] = "air",
	["cloudburst_totem"] = "water",
	["earth_elemental_totem"] = "earth",
	["earthbind_totem"] = "earth",
	["earthgrab_totem"] = "earth",
	["fire_elemental_totem"] = "fire",
	["grounding_totem"] = "air",
	["healing_stream_totem"] = "water",
	["healing_tide_totem"] = "water",
	["magma_totem"] = "fire",
	["mana_tide_totem"] = "water",
	["searing_totem"] = "fire",
	["spirit_link_totem"] = "air",
	["storm_elemental_totem"] = "air",
	["stone_bulwark_totem"] = "earth",
	["tremor_totem"] = "earth",
	["windwalk_totem"] = "air",
}

local self_outputPool = OvalePool("OvaleSimulationCraft_outputPool")
local self_childrenPool = OvalePool("OvaleSimulationCraft_childrenPool")
local self_pool = OvalePool("OvaleSimulationCraft_pool")
do
	self_pool.Clean = function(self, node)
		if node.child then
			self_childrenPool:Release(node.child)
			node.child = nil
		end
	end
end

-- Save the most recent profile entered into the SimulationCraft input window.
local self_lastSimC = nil
-- Save the most recent script translated from the profile in the SimulationCraft input window.
local self_lastScript = nil

do
	-- Add a slash command "/ovale simc" to access the GUI for this module.
	local actions = {
		simc  = {
			name = "SimulationCraft",
			type = "execute",
			func = function()
				local appName = OvaleSimulationCraft:GetName()
				AceConfigDialog:SetDefaultSize(appName, 700, 550)
				AceConfigDialog:Open(appName)
			end,
		},
	}
	-- Inject into OvaleOptions.
	for k, v in pairs(actions) do
		OvaleOptions.options.args.actions.args[k] = v
	end
end
--</private-static-properties>

--<private-static-methods>
-- Implementation of PHP-like print_r() taken from http://lua-users.org/wiki/TableSerialization.
-- This is used to print out a table, but has been modified to print out an AST.
local function print_r(node, indent, done, output)
	done = done or {}
	output = output or {}
	indent = indent or ''
	for key, value in pairs(node) do
		if type(value) == "table" then
			if done[value] then
				tinsert(output, indent .. "[" .. tostring(key) .. "] => (self_reference)")
			else
				-- Shortcut conditional allocation
				done[value] = true
				tinsert(output, indent .. "[" .. tostring(key) .. "] => {")
				print_r(value, indent .. "    ", done, output)
				tinsert(output, indent .. "}")
			end
		else
			tinsert(output, indent .. "[" .. tostring(key) .. "] => " .. tostring(value))
		end
	end
	return output
end

-- Get a new node from the pool and save it in the nodes array.
local function NewNode(nodeList, hasChild)
	local node = self_pool:Get()
	if nodeList then
		local nodeId = #nodeList + 1
		node.nodeId = nodeId
		nodeList[nodeId] = node
	end
	if hasChild then
		node.child = self_childrenPool:Get()
	end
	return node
end

--[[---------------------------------------------
	Lexer functions (for use with OvaleLexer)
--]]---------------------------------------------
local function TokenizeName(token)
	if KEYWORD[token] then
		return yield("keyword", token)
	else
		return yield("name", token)
	end
end

local function TokenizeNumber(token, options)
	if options and options.number then
		token = tonumber(token)
	end
	return yield("number", token)
end

local function Tokenize(token)
	return yield(token, token)
end

local function NoToken()
	return yield(nil)
end

do
	MATCHES = {
		{ "^%d+%.?%d*", TokenizeNumber },
		{ "^[%a_][%w_]*[.:]?[%w_.]*", TokenizeName },
		{ "^!=", Tokenize },
		{ "^<=", Tokenize },
		{ "^>=", Tokenize },
		{ "^!~", Tokenize },
		{ "^.", Tokenize },
		{ "^$", NoToken },
	}
end

local function GetTokenIterator(s)
	local exclude = { space = false, comments = false }
	return OvaleLexer.scan(s, MATCHES, exclude)
end

--[[------------------------
	"Unparser" functions
--]]------------------------

-- Return the precedence of an operator in the given node.
-- Returns nil if the node is not an expression node.
local function GetPrecedence(node)
	local precedence = node.precedence
	if not precedence then
		local operator = node.operator
		if operator then
			if node.expressionType == "unary" and UNARY_OPERATOR[operator] then
				precedence = UNARY_OPERATOR[operator][2]
			elseif node.expressionType == "binary" and BINARY_OPERATOR[operator] then
				precedence = BINARY_OPERATOR[operator][2]
			end
		end
	end
	return precedence
end

local UNPARSE_VISITOR = nil

local function Unparse(node)
	local visitor = UNPARSE_VISITOR[node.type]
	if not visitor then
		Ovale:FormatPrint("Unable to unparse node of type '%s'.", node.type)
	else
		return visitor(node)
	end
end

local function UnparseAction(node)
	local output = self_outputPool:Get()
	output[#output + 1] = node.name
	for modifier, expressionNode in pairs(node.child) do
		output[#output + 1] = modifier .. "=" .. Unparse(expressionNode)
	end
	local s = tconcat(output, ",")
	self_outputPool:Release(output)
	return s
end

local function UnparseActionList(node)
	local output = self_outputPool:Get()
	local listName
	if node.name == "default" then
		listName = "action"
	else
		listName = "action." .. node.name
	end
	output[#output + 1] = ""
	for i, actionNode in pairs(node.child) do
		local operator = (i == 1) and "=" or "+=/"
		output[#output + 1] = listName .. operator .. Unparse(actionNode)
	end
	local s = tconcat(output, "\n")
	self_outputPool:Release(output)
	return s
end

local function UnparseExpression(node)
	local expression
	local precedence = GetPrecedence(node)
	if node.expressionType == "unary" then
		local rhsExpression
		local rhsNode = node.child[1]
		local rhsPrecedence = GetPrecedence(rhsNode)
		if rhsPrecedence and precedence >= rhsPrecedence then
			rhsExpression = "(" .. Unparse(rhsNode) .. ")"
		else
			rhsExpression = Unparse(rhsNode)
		end
		expression = node.operator .. rhsExpression
	elseif node.expressionType == "binary" then
		local lhsExpression, rhsExpression
		local lhsNode = node.child[1]
		local lhsPrecedence = GetPrecedence(lhsNode)
		if lhsPrecedence and lhsPrecedence < precedence then
			lhsExpression = "(" .. Unparse(lhsNode) .. ")"
		else
			lhsExpression = Unparse(lhsNode)
		end
		local rhsNode = node.child[2]
		local rhsPrecedence = GetPrecedence(rhsNode)
		if rhsPrecedence and precedence > rhsPrecedence then
			rhsExpression = "(" .. Unparse(rhsNode) .. ")"
		elseif rhsPrecedence and precedence == rhsPrecedence then
			if BINARY_OPERATOR[node.operator][3] == "associative" then
				rhsExpression = Unparse(rhsNode)
			else
				rhsExpression = "{ " .. Unparse(rhsNode) .. " }"
			end
		else
			rhsExpression = Unparse(rhsNode)
		end
		expression = lhsExpression .. node.operator .. rhsExpression
	end
	return expression
end

local function UnparseFunction(node)
	return node.name .. "(" .. Unparse(node.child[1]) .. ")"
end

local function UnparseNumber(node)
	return tostring(node.value)
end

local function UnparseOperand(node)
	return node.name
end

do
	UNPARSE_VISITOR = {
		["action"] = UnparseAction,
		["action_list"] = UnparseActionList,
		["arithmetic"] = UnparseExpression,
		["compare"] = UnparseExpression,
		["function"] = UnparseFunction,
		["logical"] = UnparseExpression,
		["number"] = UnparseNumber,
		["operand"] = UnparseOperand,
	}
end

--[[--------------------
	Parser functions
--]]--------------------

-- Prints the error message and the next 20 tokens from tokenStream.
local function SyntaxError(tokenStream, ...)
	Ovale:FormatPrint(...)
	local context = { "Next tokens:" }
	for i = 1, 20 do
		local tokenType, token = tokenStream:Peek(i)
		if tokenType then
			context[#context + 1] = token
		else
			context[#context + 1] = "<EOS>"
			break
		end
	end
	Ovale:Print(tconcat(context, " "))
end

-- Left-rotate tree to preserve precedence.
local function LeftRotateTree(node)
	local rhsNode = node.child[2]
	while node.type == rhsNode.type and node.operator == rhsNode.operator and BINARY_OPERATOR[node.operator][3] == "associative" and rhsNode.expressionType == "binary" do
		node.child[2] = rhsNode.child[1]
		rhsNode.child[1] = node
		node = rhsNode
		rhsNode = node.child[2]
	end
	return node
end

-- Forward declarations of parser functions needed to implement a recursive descent parser.
local ParseAction = nil
local ParseActionList = nil
local ParseExpression = nil
local ParseFunction = nil
local ParseModifier = nil
local ParseNumber = nil
local ParseOperand = nil
local ParseParentheses = nil
local ParseSimpleExpression = nil

local function TicksRemainTranslationHelper(p1, p2, p3, p4)
	if p4 then
		return p1 .. p2 .. "<" .. tostring(tonumber(p4) + 1)
	else
		return p1 .. "<" .. tostring(tonumber(p3) + 1)
	end
end

ParseAction = function(action, nodeList, annotation)
	local ok = true
	local stream = action
	do
		-- Fix "|" being silently replaced by "||" in WoW strings entered via an edit box.
		stream = gsub(stream, "||", "|")
	end
	do
		-- Fix bugs in SimulationCraft action lists.
		-- ",," into ","
		stream = gsub(stream, ",,", ",")
	end
	do
		-- Changes to SimulationCraft action lists for easier translation into Ovale timespan concept.
		-- "active_dot.dotName=0" into "!(active_dot.dotName>0)"
		stream = gsub(stream, "(active_dot%.[%w_]+)=0", "!(%1>0)")
		-- "cooldown_remains=0" into "!(cooldown_remains>0)"
		stream = gsub(stream, "([^_%.])(cooldown_remains)=0", "%1!(%2>0)")
		stream = gsub(stream, "([a-z_%.]+%.cooldown_remains)=0", "!(%1>0)")
		-- "remains=0" into "!(remains>0)"
		stream = gsub(stream, "([^_%.])(remains)=0", "%1!(%2>0)")
		stream = gsub(stream, "([a-z_%.]+%.remains)=0", "!(%1>0)")
		-- "ticks_remain=1" into "ticks_remain<2"
		-- "ticks_remain<=N" into "ticks_remain<N+1"
		stream = gsub(stream, "([^_%.])(ticks_remain)(<?=)([0-9]+)", TicksRemainTranslationHelper)
		stream = gsub(stream, "([a-z_%.]+%.ticks_remain)(<?=)([0-9]+)", TicksRemainTranslationHelper)
	end
	local tokenStream = OvaleLexer("SimulationCraft", GetTokenIterator(stream))
	-- Consume the action.
	local name
	do
		local tokenType, token = tokenStream:Consume()
		if (tokenType == "keyword" and SPECIAL_ACTION[token]) or tokenType == "name" then
			name = token
		else
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing action line; name or special action expected.", token)
			ok = false
		end
	end
	local child = self_childrenPool:Get()
	if ok then
		local tokenType, token = tokenStream:Peek()
		while ok and tokenType do
			if tokenType == "," then
				-- Consume the ',' token.
				tokenStream:Consume()
				local modifier, expressionNode
				ok, modifier, expressionNode = ParseModifier(tokenStream, nodeList, annotation)
				if ok then
					child[modifier] = expressionNode
					tokenType, token = tokenStream:Peek()
				end
			else
				SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing action line; ',' expected.", token)
				ok = false
			end
		end
	end
	local node
	if ok then
		node = NewNode(nodeList)
		node.type = "action"
		node.action = action
		node.name = name
		node.child = child
	else
		self_childrenPool:Release(child)
	end
	return ok, node
end

ParseActionList = function(name, actionList, nodeList, annotation)
	local ok = true
	local child = self_childrenPool:Get()
	for action in gmatch(actionList, "[^/]+") do
		local actionNode
		ok, actionNode = ParseAction(action, nodeList, annotation)
		if ok then
			child[#child + 1] = actionNode
		else
			break
		end
	end
	local node
	if ok then
		node = NewNode(nodeList)
		node.type = "action_list"
		node.name = name
		node.child = child
	else
		self_childrenPool:Release(child)
	end
	return ok, node
end

--[[
	Operator-precedence parser for logical and arithmetic expressions.
	Implementation taken from Wikipedia:
		http://en.wikipedia.org/wiki/Operator-precedence_parser
--]]
ParseExpression = function(tokenStream, nodeList, annotation, minPrecedence)
	minPrecedence = minPrecedence or 0
	local ok = true
	local node

	-- Check for unary operator expressions first as they decorate the underlying expression.
	do
		local tokenType, token = tokenStream:Peek()
		if tokenType then
			local opInfo = UNARY_OPERATOR[token]
			if opInfo then
				local opType, precedence = opInfo[1], opInfo[2]
				local asType = (opType == "logical") and "boolean" or "value"
				tokenStream:Consume()
				local operator = token
				local rhsNode
				ok, rhsNode = ParseExpression(tokenStream, nodeList, annotation, precedence)
				if ok then
					if operator == "-" and rhsNode.type == "number" then
						-- Elide the unary negation operator into the number.
						rhsNode.value = -1 * rhsNode.value
						node = rhsNode
					else
						node = NewNode(nodeList, true)
						node.type = opType
						node.expressionType = "unary"
						node.operator = operator
						node.precedence = precedence
						node.child[1] = rhsNode
						rhsNode.asType = asType
					end
				end
			else
				ok, node = ParseSimpleExpression(tokenStream, nodeList, annotation)
				if ok and node then
					node.asType = "boolean"
				end
			end
		end
	end

	-- Peek at the next token to see if it is a binary operator.
	while ok do
		local keepScanning = false
		local tokenType, token = tokenStream:Peek()
		if tokenType then
			local opInfo = BINARY_OPERATOR[token]
			if opInfo then
				local opType, precedence = opInfo[1], opInfo[2]
				local asType = (opType == "logical") and "boolean" or "value"
				if precedence and precedence > minPrecedence then
					keepScanning = true
					tokenStream:Consume()
					local operator = token
					local lhsNode = node
					local rhsNode
					ok, rhsNode = ParseExpression(tokenStream, nodeList, annotation, precedence)
					if ok then
						node = NewNode(nodeList, true)
						node.type = opType
						node.expressionType = "binary"
						node.operator = operator
						node.precedence = precedence
						node.child[1] = lhsNode
						node.child[2] = rhsNode
						lhsNode.asType = asType
						rhsNode.asType = asType
						-- Left-rotate tree to preserve precedence.
						node = LeftRotateTree(node)
					end
				end
			end
		end
		if not keepScanning then
			break
		end
	end

	return ok, node
end

ParseFunction = function(tokenStream, nodeList, annotation)
	local ok = true
	local name
	-- Consume the name.
	do
		local tokenType, token = tokenStream:Consume()
		if tokenType == "keyword" and FUNCTION_KEYWORD[token] then
			name = token
		else
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing FUNCTION; name expected.", token)
			ok = false
		end
	end
	-- Consume the left parenthesis.
	if ok then
		local tokenType, token = tokenStream:Consume()
		if tokenType ~= "(" then
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing FUNCTION; '(' expected.", token)
			ok = false
		end
	end
	-- Consume the function argument.
	local argumentNode
	if ok then
		ok, argumentNode = ParseExpression(tokenStream, nodeList, annotation)
	end
	-- Consume the right parenthesis.
	if ok then
		local tokenType, token = tokenStream:Consume()
		if tokenType ~= ")" then
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing FUNCTION; ')' expected.", token)
			ok = false
		end
	end
	-- Create the AST node.
	local node
	if ok then
		node = NewNode(nodeList, true)
		node.type = "function"
		node.name = name
		node.child[1] = argumentNode
	end
	return ok, node
end

ParseModifier = function(tokenStream, nodeList, annotation)
	local ok = true
	local name
	do
		local tokenType, token = tokenStream:Consume()
		if tokenType == "keyword" and MODIFIER_KEYWORD[token] then
			name = token
		else
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing action line; expression keyword expected.", token)
			ok = false
		end
	end
	if ok then
		-- Consume the '=' token.
		local tokenType, token = tokenStream:Consume()
		if tokenType ~= "=" then
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing action line; '=' expected.", token)
			ok = false
		end
	end
	local expressionNode
	if ok then
		ok, expressionNode = ParseExpression(tokenStream, nodeList, annotation)
	end
	return ok, name, expressionNode
end

ParseNumber = function(tokenStream, nodeList, annotation)
	local ok = true
	local value
	-- Consume the number.
	do
		local tokenType, token = tokenStream:Consume()
		if tokenType == "number" then
			value = tonumber(token)
		else
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing NUMBER; number expected.", token)
			ok = false
		end
	end
	-- Create the AST node.
	local node
	if ok then
		node = NewNode(nodeList)
		node.type = "number"
		node.value = value
	end
	return ok, node
end

ParseOperand = function(tokenStream, nodeList, annotation)
	local ok = true
	local name
	-- Consume the operand.
	do
		local tokenType, token = tokenStream:Consume()
		if tokenType == "name" then
			name = token
		elseif tokenType == "keyword" and token == "target" then
			-- Allow a bare "target" to be used as an operand.
			name = token
		else
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing OPERAND; operand expected.", token)
			ok = false
		end
	end
	-- Create the AST node.
	local node
	if ok then
		node = NewNode(nodeList)
		node.type = "operand"
		node.name = name
		node.rune = RUNE_OPERAND[name]
		annotation.operand = annotation.operand or {}
		annotation.operand[#annotation.operand + 1] = node
	end
	return ok, node
end

ParseParentheses = function(tokenStream, nodeList, annotation)
	local ok = true
	local leftToken, rightToken
	-- Consume the left parenthesis.
	do
		local tokenType, token = tokenStream:Consume()
		if tokenType == "(" then
			leftToken, rightToken = "(", ")"
		elseif tokenType == "{" then
			leftToken, rightToken = "{", "}"
		else
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing PARENTHESES; '(' or '{' expected.", token)
			ok = false
		end
	end
	-- Consume the inner expression.
	local node
	if ok then
		ok, node = ParseExpression(tokenStream, nodeList, annotation)
	end
	-- Consume the right parenthesis.
	if ok then
		local tokenType, token = tokenStream:Consume()
		if tokenType ~= rightToken then
			SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing PARENTHESES; '%s' expected.", token, rightToken)
			ok = false
		end
	end
	-- Create the AST node.
	if ok then
		node.left = leftToken
		node.right = rightToken
	end
	return ok, node
end

ParseSimpleExpression = function(tokenStream, nodeList, annotation)
	local ok = true
	local node
	local tokenType, token = tokenStream:Peek()
	if tokenType == "number" then
		ok, node = ParseNumber(tokenStream, nodeList, annotation)
	elseif tokenType == "keyword" then
		if FUNCTION_KEYWORD[token] then
			ok, node = ParseFunction(tokenStream, nodeList, annotation)
		elseif token == "target" then
			ok, node = ParseOperand(tokenStream, nodeList, annotation)
		end
	elseif tokenType == "name" then
		ok, node = ParseOperand(tokenStream, nodeList, annotation)
	elseif tokenType == "(" then
		ok, node = ParseParentheses(tokenStream, nodeList, annotation)
	else
		SyntaxError(tokenStream, "Syntax error: unexpected token '%s' when parsing SIMPLE EXPRESSION", token)
		tokenStream:Consume()
		ok = false
	end
	return ok, node
end

--[[-----------------------------
	Code generation functions
--]]-----------------------------

local CamelCase = nil
do
	local function CamelCaseHelper(first, rest)
		return strupper(first) .. strlower(rest)
	end

	CamelCase = function(s)
		local tc = gsub(s, "(%a)(%w*)", CamelCaseHelper)
		return gsub(tc, "[%s_]", "")
	end
end

local function OvaleFunctionName(name, annotation)
	local output = self_outputPool:Get()
	local profileName, class, specialization = annotation.name, annotation.class, annotation.specialization
	if specialization then
		output[#output + 1] = specialization
	end
	if strmatch(profileName, "_1[hH]_") then
		if class == "DEATHKNIGHT" and specialization == "frost" then
			output[#output + 1] = "dual wield"
		elseif class == "WARRIOR" and specialization == "fury" then
			output[#output + 1] = "single minded fury"
		end
	elseif strmatch(profileName, "_2[hH]_") then
		if class == "DEATHKNIGHT" and specialization == "frost" then
			output[#output + 1] = "two hander"
		elseif class == "WARRIOR" and specialization == "fury" then
			output[#output + 1] = "titans grip"
		end
	end
	output[#output + 1] = name
	output[#output + 1] = "actions"
	local outputString = CamelCase(tconcat(output, " "))
	self_outputPool:Release(output)
	return outputString
end

local function AddSymbol(annotation, symbol)
	local symbolTable = annotation.symbolTable or {}
	-- Add the symbol to the table if it's not already present and it's not a globally-defined spell list name.
	if not symbolTable[symbol] and not OvaleData.buffSpellList[symbol] then
		symbolTable[symbol] = true
		symbolTable[#symbolTable + 1] = symbol
	end
	annotation.symbolTable = symbolTable
end

local function AddPerClassSpecialization(tbl, name, info, class, specialization)
	class = class or "ALL_CLASSES"
	specialization = specialization or "ALL_SPECIALIZATIONS"
	tbl[class] = tbl[class] or {}
	tbl[class][specialization] = tbl[class][specialization] or {}
	tbl[class][specialization][name] = info
end

local function GetPerClassSpecialization(tbl, name, class, specialization)
	local info
	while not info do
		while not info do
			if tbl[class] and tbl[class][specialization] and tbl[class][specialization][name] then
				info = tbl[class][specialization][name]
			end
			if specialization ~= "ALL_SPECIALIZATIONS" then
				specialization = "ALL_SPECIALIZATIONS"
			else
				break
			end
		end
		if class ~= "ALL_CLASSES" then
			class = "ALL_CLASSES"
		else
			break
		end
	end
	return info
end

local function AddDisambiguation(name, info, class, specialization)
	AddPerClassSpecialization(EMIT_DISAMBIGUATION, name, info, class, specialization)
end

local function Disambiguate(name, class, specialization)
	return GetPerClassSpecialization(EMIT_DISAMBIGUATION, name, class, specialization) or name
end

local function InitializeDisambiguation()
	AddDisambiguation("bloodlust_buff",			"burst_haste_buff")
	AddDisambiguation("trinket_proc_all_buff",	"trinket_proc_any_buff")
	-- Death Knight
	AddDisambiguation("arcane_torrent",			"arcane_torrent_runicpower",	"DEATHKNIGHT")
	AddDisambiguation("blood_fury",				"blood_fury_ap",				"DEATHKNIGHT")
	AddDisambiguation("breath_of_sindragosa_debuff",	"breath_of_sindragosa_buff",	"DEATHKNIGHT")
	AddDisambiguation("soul_reaper",			"soul_reaper_blood",			"DEATHKNIGHT",	"blood")
	AddDisambiguation("soul_reaper",			"soul_reaper_frost",			"DEATHKNIGHT",	"frost")
	AddDisambiguation("soul_reaper",			"soul_reaper_unholy",			"DEATHKNIGHT",	"unholy")
	-- Druid
	AddDisambiguation("arcane_torrent",			"arcane_torrent_energy",		"DRUID")
	AddDisambiguation("berserk",				"berserk_bear",					"DRUID",		"guardian")
	AddDisambiguation("berserk",				"berserk_cat",					"DRUID",		"feral")
	AddDisambiguation("blood_fury",				"blood_fury_apsp",				"DRUID")
	AddDisambiguation("dream_of_cenarius",		"dream_of_cenarius_caster",		"DRUID",		"balance")
	AddDisambiguation("dream_of_cenarius",		"dream_of_cenarius_melee",		"DRUID",		"feral")
	AddDisambiguation("dream_of_cenarius",		"dream_of_cenarius_tank",		"DRUID",		"guardian")
	AddDisambiguation("force_of_nature",		"force_of_nature_caster",		"DRUID",		"balance")
	AddDisambiguation("force_of_nature",		"force_of_nature_melee",		"DRUID",		"feral")
	AddDisambiguation("force_of_nature",		"force_of_nature_tank",			"DRUID",		"guardian")
	AddDisambiguation("heart_of_the_wild",		"heart_of_the_wild_tank",		"DRUID",		"guardian")
	AddDisambiguation("incarnation",			"incarnation_caster",			"DRUID",		"balance")
	AddDisambiguation("incarnation",			"incarnation_melee",			"DRUID",		"feral")
	AddDisambiguation("incarnation",			"incarnation_tank",				"DRUID",		"guardian")
	AddDisambiguation("moonfire",				"moonfire_cat",					"DRUID",		"feral")
	AddDisambiguation("omen_of_clarity",		"omen_of_clarity_melee",		"DRUID",		"feral")
	AddDisambiguation("rejuvenation_debuff",	"rejuvenation_buff",			"DRUID")
	-- Hunter
	AddDisambiguation("arcane_torrent",			"arcane_torrent_focus",			"HUNTER")
	AddDisambiguation("blood_fury",				"blood_fury_ap",				"HUNTER")
	AddDisambiguation("focusing_shot",			"focusing_shot_marksmanship",	"HUNTER",		"marksmanship")
	-- Mage
	AddDisambiguation("arcane_torrent",			"arcane_torrent_mana",			"MAGE")
	AddDisambiguation("arcane_charge_buff",		"arcane_charge_debuff",			"MAGE",			"arcane")
	AddDisambiguation("blood_fury",				"blood_fury_sp",				"MAGE")
	-- Monk
	AddDisambiguation("arcane_torrent",			"arcane_torrent_chi",			"MONK")
	AddDisambiguation("blood_fury",				"blood_fury_apsp",				"MONK")
	AddDisambiguation("chi_explosion",			"chi_explosion_heal",			"MONK",			"mistweaver")
	AddDisambiguation("chi_explosion",			"chi_explosion_melee",			"MONK",			"windwalker")
	AddDisambiguation("chi_explosion",			"chi_explosion_tank",			"MONK",			"brewmaster")
	AddDisambiguation("zen_sphere_debuff",		"zen_sphere_buff",				"MONK")
	-- Paladin
	AddDisambiguation("arcane_torrent",			"arcane_torrent_holy",			"PALADIN")
	AddDisambiguation("avenging_wrath",			"avenging_wrath_melee",			"PALADIN",		"retribution")
	AddDisambiguation("blood_fury",				"blood_fury_apsp",				"PALADIN")
	AddDisambiguation("sacred_shield_debuff",	"sacred_shield_buff",			"PALADIN")
	-- Priest
	AddDisambiguation("arcane_torrent",			"arcane_torrent_mana",			"PRIEST")
	AddDisambiguation("blood_fury",				"blood_fury_sp",				"PRIEST")
	AddDisambiguation("cascade",				"cascade_caster",				"PRIEST",		"shadow")
	AddDisambiguation("divine_star",			"divine_star_caster",			"PRIEST",		"shadow")
	AddDisambiguation("halo",					"halo_caster",					"PRIEST",		"shadow")
	AddDisambiguation("devouring_plague_tick",	"devouring_plague",				"PRIEST")
	-- Rogue
	AddDisambiguation("arcane_torrent",			"arcane_torrent_energy",		"ROGUE")
	AddDisambiguation("blood_fury",				"blood_fury_ap",				"ROGUE")
	AddDisambiguation("stealth_buff",			"stealthed_buff",				"ROGUE")
	-- Shaman
	AddDisambiguation("arcane_torrent",			"arcane_torrent_mana",			"SHAMAN")
	AddDisambiguation("ascendance",				"ascendance_caster",			"SHAMAN",		"elemental")
	AddDisambiguation("ascendance",				"ascendance_melee",				"SHAMAN",		"enhancement")
	AddDisambiguation("blood_fury",				"blood_fury_apsp",				"SHAMAN")
	-- Warlock
	AddDisambiguation("arcane_torrent",			"arcane_torrent_mana",			"WARLOCK")
	AddDisambiguation("blood_fury",				"blood_fury_sp",				"WARLOCK")
	AddDisambiguation("dark_soul",				"dark_soul_instability",		"WARLOCK",		"destruction")
	AddDisambiguation("dark_soul",				"dark_soul_knowledge",			"WARLOCK",		"demonology")
	AddDisambiguation("dark_soul",				"dark_soul_misery",				"WARLOCK",		"affliction")
	AddDisambiguation("glyph_of_dark_soul_instability",	"glyph_of_dark_soul",	"WARLOCK",		"destruction")
	AddDisambiguation("glyph_of_dark_soul_knowledge",	"glyph_of_dark_soul",	"WARLOCK",		"demonology")
	AddDisambiguation("glyph_of_dark_soul_misery",		"glyph_of_dark_soul",	"WARLOCK",		"affliction")
	-- Warrior
	AddDisambiguation("arcane_torrent",			"arcane_torrent_rage",			"WARRIOR")
	AddDisambiguation("blood_fury",				"blood_fury_ap",				"WARRIOR")
	AddDisambiguation("execute",				"execute_arms",					"WARRIOR",		"arms")
	AddDisambiguation("shield_barrier",			"shield_barrier_melee",			"WARRIOR",		"arms")
	AddDisambiguation("shield_barrier",			"shield_barrier_melee",			"WARRIOR",		"fury")
	AddDisambiguation("shield_barrier",			"shield_barrier_tank",			"WARRIOR",		"protection")
end

local EMIT_VISITOR = nil
-- Forward declarations of code generation functions.
local Emit = nil
local EmitAction = nil
local EmitActionList = nil
local EmitExpression = nil
local EmitFunction = nil
local EmitModifier = nil
local EmitNumber = nil
local EmitOperand = nil
local EmitOperandAction = nil
local EmitOperandActiveDot = nil
local EmitOperandBuff = nil
local EmitOperandCharacter = nil
local EmitOperandCooldown = nil
local EmitOperandDisease = nil
local EmitOperandDot = nil
local EmitOperandGlyph = nil
local EmitOperandPet = nil
local EmitOperandRaidEvent = nil
local EmitOperandRune = nil
local EmitOperandSeal = nil
local EmitOperandSetBonus = nil
local EmitOperandSpecial = nil
local EmitOperandTalent = nil
local EmitOperandTotem = nil
local EmitOperandTrinket = nil

Emit = function(parseNode, nodeList, annotation, action)
	local visitor = EMIT_VISITOR[parseNode.type]
	if not visitor then
		Ovale:FormatPrint("Unable to emit node of type '%s'.", parseNode.type)
	else
		return visitor(parseNode, nodeList, annotation, action)
	end
end

EmitAction = function(parseNode, nodeList, annotation)
	local node
	local canonicalizedName = gsub(parseNode.name, ":", "_")
	local class = annotation.class
	local specialization = annotation.specialization
	local action = Disambiguate(canonicalizedName, class, specialization)

	if action == "auto_attack" or action == "auto_shot" then
		-- skip
	elseif action == "elixir" or action == "flask" or action == "food" then
		-- skip
	elseif action == "snapshot_stats" then
		-- skip
	else
		local bodyNode, conditionNode
		local bodyCode, conditionCode
		local expressionType = "expression"
		local modifier = parseNode.child
		local isSpellAction = true
		if class == "DEATHKNIGHT" and action == "antimagic_shell" then
			-- Only suggest Anti-Magic Shell if there is incoming damage to absorb to generate runic power.
			conditionCode = "IncomingDamage(1.5) > 0"
		elseif class == "DEATHKNIGHT" and action == "blood_tap" then
			-- Blood Tap requires a minimum of five stacks of Blood Charge to be on the player.
			local buffName = "blood_charge_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffStacks(%s) >= 5", buffName)
		elseif class == "DEATHKNIGHT" and action == "dark_transformation" then
			-- Dark Transformation requires a five stacks of Shadow Infusion to be on the player/pet.
			local buffName = "shadow_infusion_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffStacks(%s) >= 5", buffName)
		elseif class == "DEATHKNIGHT" and action == "horn_of_winter" then
			-- Only cast Horn of Winter if not already raid-buffed.
			conditionCode = "BuffExpires(attack_power_multiplier_buff any=1)"
		elseif class == "DEATHKNIGHT" and action == "mind_freeze" then
			bodyCode = "InterruptActions()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "DEATHKNIGHT" and action == "plague_leech" then
			-- Plague Leech requires diseases to exist on the target.
			conditionCode = "target.DiseasesTicking()"
		elseif class == "DRUID" and specialization == "guardian" and action == "rejuvenation" then
			-- Only cast Rejuvenation as a guardian druid if it is Enhanced Rejuvenation (castable in bear form).
			local spellName = "enhanced_rejuvenation"
			AddSymbol(annotation, spellName)
			conditionCode = format("SpellKnown(%s)", spellName)
		elseif class == "DRUID" and action == "prowl" then
			-- Don't Prowl if already stealthed.
			conditionCode = "BuffExpires(stealthed_buff any=1)"
		elseif class == "DRUID" and action == "pulverize" then
			-- Pulverize requires 3 stacks of Lacerate on the target.
			local debuffName = "lacerate_debuff"
			AddSymbol(annotation, debuffName)
			conditionCode = format("target.DebuffStacks(%s) >= 3", debuffName)
		elseif class == "DRUID" and action == "skull_bash" then
			bodyCode = "InterruptActions()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "HUNTER" and action == "exotic_munitions" then
			if modifier.ammo_type then
				local name = Unparse(modifier.ammo_type)
				action = name .. "_ammo"
				-- Always have at least 20 minutes of an Exotic Munitions buff applied when out of combat.
				local buffName = "exotic_munitions_buff"
				AddSymbol(annotation, buffName)
				conditionCode = format("BuffRemaining(%s) < 1200", buffName)
			else
				isSpellAction = false
			end
		elseif class == "HUNTER" and action == "explosive_trap" then
			-- Glyph of Explosive Trap removes the damage component from Explosive Trap.
			local glyphName = "glyph_of_explosive_trap"
			AddSymbol(annotation, glyphName)
			annotation.trap_launcher = class
			conditionCode = format("CheckBoxOn(opt_trap_launcher) and not Glyph(%s)", glyphName)
		elseif class == "HUNTER" and action == "focus_fire" then
			-- Focus Fire requires at least one stack of Frenzy.
			local buffName = "frenzy_buff"
			AddSymbol(annotation, buffName)
			if modifier.five_stacks then
				local value = tonumber(Unparse(modifier.five_stacks))
				if value == 1 then
					conditionCode = format("BuffStacks(%s any=1) == 5", buffName)
				end
			end
			if not conditionCode then
				conditionCode = format("BuffPresent(%s any=1)", buffName)
			end
		elseif class == "HUNTER" and action == "kill_command" then
			-- Kill Command requires that a pet that can move freely.
			conditionCode = "pet.Present() and not pet.IsIncapacitated() and not pet.IsFeared() and not pet.IsStunned()"
		elseif class == "HUNTER" and strsub(action, -5) == "_trap" then
			annotation.trap_launcher = class
			conditionCode = "CheckBoxOn(opt_trap_launcher)"
		elseif class == "MAGE" and action == "arcane_brilliance" then
			-- Only cast Arcane Brilliance if not already raid-buffed.
			conditionCode = "BuffExpires(critical_strike_buff any=1) or BuffExpires(spell_power_multiplier_buff any=1)"
		elseif class == "MAGE" and action == "arcane_missiles" then
			-- Arcane Missiles can only be fired if the Arcane Missiles! buff is present.
			local buffName = "arcane_missiles_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif class == "MAGE" and action == "counterspell" then
			bodyCode = "InterruptActions()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "MAGE" and action == "start_pyro_chain" then
			bodyCode = "SetState(pyro_chain 1)"
			isSpellAction = false
		elseif class == "MAGE" and action == "stop_pyro_chain" then
			bodyCode = "SetState(pyro_chain 0)"
			isSpellAction = false
		elseif class == "MAGE" and action == "time_warp" then
			-- Only suggest Time Warp if it will have an effect.
			conditionCode = "CheckBoxOn(opt_time_warp) and DebuffExpires(burst_haste_debuff any=1)"
			annotation[action] = class
		elseif class == "MAGE" and action == "water_elemental" then
			-- Only suggest summoning the Water Elemental if the pet is not already summoned.
			conditionCode = "not pet.Present()"
		elseif class == "MONK" and action == "chi_burst" then
			-- Only suggest Chi Burst if it's toggled on.
			conditionCode = "CheckBoxOn(opt_chi_burst)"
			annotation[action] = class
		elseif class == "MONK" and action == "chi_sphere" then
			-- skip
			isSpellAction = false
		elseif class == "MONK" and action == "gift_of_the_ox" then
			-- skip
			isSpellAction = false
		elseif class == "MONK" and action == "touch_of_death" then
			-- Touch of Death can only be used if the Death Note buff is present on the player.
			local buffName = "death_note_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif class == "PALADIN" and action == "blessing_of_kings" then
			-- Only cast Blessing of Kings if it won't overwrite the player's own Blessing of Might.
			conditionCode = "BuffExpires(mastery_buff)"
		elseif class == "PALADIN" and action == "rebuke" then
			bodyCode = "InterruptActions()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "PRIEST" and action == "insanity" then
			local buffName = "shadow_word_insanity_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif class == "ROGUE" and action == "apply_poison" then
			if modifier.lethal then
				local name = Unparse(modifier.lethal)
				action = name .. "_poison"
				-- Always have at least 20 minutes of a lethal poison applied when out of combat.
				local buffName = "lethal_poison_buff"
				AddSymbol(annotation, buffName)
				conditionCode = format("BuffRemaining(%s) < 1200", buffName)
			else
				isSpellAction = false
			end
		elseif class == "ROGUE" and action == "honor_among_thieves" then
			-- skip
			isSpellAction = false
		elseif class == "ROGUE" and action == "kick" then
			bodyCode = "InterruptActions()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "ROGUE" and specialization == "subtlety" and action == "slice_and_dice" then
			-- The game does not prevent a Subtlety rogue from overwriting a longer Slice and Dice buff with a shorter one.
			local buffName = "slice_and_dice_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffRemaining(%s) < 0.3 * BaseDuration(%s)", buffName, buffName)
		elseif class == "ROGUE" and action == "stealth" then
			-- Don't Stealth if already stealthed.
			conditionCode = "BuffExpires(stealthed_buff any=1)"
		elseif class == "SHAMAN" and action == "bloodlust" then
			bodyCode = "Bloodlust()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "SHAMAN" and action == "lava_beam" then
			-- Lava Beam is the elemental Ascendance version of Chain Lightning.
			local buffName = "ascendance_caster_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif class == "SHAMAN" and action == "magma_totem" then
			-- Only suggest Magma Totem if within melee range of the target.
			local spellName = "primal_strike"
			AddSymbol(annotation, spellName)
			conditionCode = format("target.InRange(%s)", spellName)
		elseif class == "SHAMAN" and action == "windstrike" then
			-- Windstrike is the enhancement Ascendance version of Stormstrike.
			local buffName = "ascendance_melee_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif class == "SHAMAN" and action == "wind_shear" then
			bodyCode = "InterruptActions()"
			annotation[action] = class
			isSpellAction = false
		elseif class == "WARLOCK" and action == "cancel_metamorphosis" then
			local spellName = "metamorphosis"
			local buffName = "metamorphosis_buff"
			AddSymbol(annotation, spellName)
			AddSymbol(annotation, buffName)
			bodyCode = format("Spell(%s text=cancel)", spellName)
			conditionCode = format("BuffPresent(%s)", buffName)
			isSpellAction = false
		elseif class == "WARLOCK" and action == "felguard_felstorm" then
			conditionCode = "pet.Present() and pet.CreatureFamily(Felguard)"
		elseif class == "WARLOCK" and action == "grimoire_of_sacrifice" then
			-- Grimoire of Sacrifice requires a pet to already be summoned.
			conditionCode = "pet.Present()"
		elseif class == "WARLOCK" and action == "service_pet" then
			if annotation.pet then
				local spellName = "grimoire_" .. annotation.pet
				AddSymbol(annotation, spellName)
				bodyCode = format("Spell(%s)", spellName)
			else
				bodyCode = "Texture(spell_nature_removecurse help=ServicePet)"
			end
			isSpellAction = false
		elseif class == "WARLOCK" and action == "summon_pet" then
			if annotation.pet then
				local spellName = "summon_" .. annotation.pet
				AddSymbol(annotation, spellName)
				bodyCode = format("Spell(%s)", spellName)
			else
				bodyCode = "Texture(spell_nature_removecurse help=L(summon_pet))"
			end
			-- Only summon a pet if one is not already summoned.
			conditionCode = "not pet.Present()"
			isSpellAction = false
		elseif class == "WARLOCK" and action == "wrathguard_wrathstorm" then
			conditionCode = "pet.Present() and pet.CreatureFamily(Wrathguard)"
		elseif class == "WARRIOR" and action == "charge" then
			conditionCode = "target.InRange(charge)"
		elseif class == "WARRIOR" and action == "heroic_leap" then
			-- Use Charge as a range-finder for Heroic Leap.
			local spellName = "charge"
			AddSymbol(annotation, spellName)
			conditionCode = format("target.InRange(%s)", spellName)
		elseif class == "WARRIOR" and action == "victory_rush" then
			-- Victory Rush requires the Victorious buff to be on the player.
			local buffName = "victorious_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif class == "WARRIOR" and action == "raging_blow" then
			-- Raging Blow can only be used if the Raging Blow buff is present on the player.
			local buffName = "raging_blow_buff"
			AddSymbol(annotation, buffName)
			conditionCode = format("BuffPresent(%s)", buffName)
		elseif action == "call_action_list" or action == "run_action_list" or action == "swap_action_list" then
			if modifier.name then
				local name = Unparse(modifier.name)
				bodyCode = OvaleFunctionName(name, annotation) .. "()"
			end
			isSpellAction = false
		elseif action == "pool_resource" then
			-- Create a special "simc_pool_resource" AST node that will be transformed in
			-- a later step into something OvaleAST can understand and unparse.
			bodyNode = OvaleAST:NewNode(nodeList)
			bodyNode.type = "simc_pool_resource"
			bodyNode.for_next = (modifier.for_next ~= nil)
			if modifier.extra_amount then
				bodyNode.extra_amount = tonumber(Unparse(modifier.extra_amount))
			end
			isSpellAction = false
		elseif action == "potion" then
			if modifier.name then
				local name = Unparse(modifier.name)
				if name == "virmens_bite" or name == "tolvir" then
					bodyCode = "UsePotionAgility()"
					annotation.use_potion_agility = class
				elseif name == "mountains" then
					bodyCode = "UsePotionArmor()"
					annotation.use_potion_armor = class
				elseif name == "jade_serpent" then
					bodyCode = "UsePotionIntellect()"
					annotation.use_potion_intellect = class
				elseif name == "mogu_power" then
					bodyCode = "UsePotionStrength()"
					annotation.use_potion_strength = class
				end
				isSpellAction = false
			end
		elseif action == "stance" then
			if modifier.choose then
				local name = Unparse(modifier.choose)
				if class == "MONK" then
					action = "stance_of_the_" .. name
				elseif class == "WARRIOR" then
					action = name .. "_stance"
				else
					action = name
				end
			else
				isSpellAction = false
			end
		elseif action == "summon_pet" then
			bodyCode = "SummonPet()"
			annotation[action] = class
			isSpellAction = false
		elseif action == "use_item" then
			if true then
				--[[
					When "use_item" is encountered in an action list, it is usually meant to use
					all of the equipped items at the same time, so all hand tinkers and on-use
					trinkets.  Assume a "UseItemActions()" function is available that does this.
				--]]
				bodyCode = "UseItemActions()"
				annotation[action] = true
			else
				if modifier.name == "name" then
					local name = Unparse(modifier.name)
					if strmatch(name, "gauntlets") or strmatch(name, "gloves") or strmatch(name, "grips") or strmatch(name, "handguards") then
						bodyCode = "Item(HandsSlot usable=1)"
					end
				elseif modifier.slot then
					local slot = Unparse(modifier.slot)
					if slot == "hands" then
						bodyCode = "Item(HandsSlot usable=1)"
					elseif strmatch(slot, "trinket") then
						bodyCode = "{ Item(Trinket0Slot usable=1) Item(Trinket1Slot usable=1) }"
						expressionType = "group"
					end
				end
			end
			isSpellAction = false
		elseif action == "wait" then
			if modifier.sec then
				-- Create a special "wait" AST node that will be transformed in
				-- a later step into something OvaleAST can understand and unparse.
				bodyNode = OvaleAST:NewNode(nodeList)
				bodyNode.type = "simc_wait"
				-- "wait,sec=expr" means to halt the processing of the action list if "expr > 0".
				conditionNode = Emit(modifier.sec, nodeList, annotation, action)
			end
			isSpellAction = false
		end
		if isSpellAction then
			AddSymbol(annotation, action)
			bodyCode = "Spell(" .. action .. ")"
		end
		annotation.astAnnotation = annotation.astAnnotation or {}
		if not bodyNode and bodyCode then
			bodyNode = OvaleAST:ParseCode(expressionType, bodyCode, nodeList, annotation.astAnnotation)
		end
		if not conditionNode and conditionCode then
			conditionNode = OvaleAST:ParseCode(expressionType, conditionCode, nodeList, annotation.astAnnotation)
		end

		-- Conditions from modifiers, if present.
		if bodyNode then
			-- Put the extra conditions on the right-most side.
			local extraConditionNode = conditionNode
			conditionNode = nil
			-- Concatenate all of the conditions from modifiers using the "and" operator.
			for modifier, expressionNode in pairs(parseNode.child) do
				local rhsNode = EmitModifier(modifier, expressionNode, nodeList, annotation, action)
				if rhsNode then
					if not conditionNode then
						conditionNode = rhsNode
					else
						local lhsNode = conditionNode
						conditionNode = OvaleAST:NewNode(nodeList, true)
						conditionNode.type = "logical"
						conditionNode.expressionType = "binary"
						conditionNode.operator = "and"
						conditionNode.child[1] = lhsNode
						conditionNode.child[2] = rhsNode
					end
				end
			end
			if extraConditionNode then
				if conditionNode then
					local lhsNode = conditionNode
					local rhsNode = extraConditionNode
					conditionNode = OvaleAST:NewNode(nodeList, true)
					conditionNode.type = "logical"
					conditionNode.expressionType = "binary"
					conditionNode.operator = "and"
					conditionNode.child[1] = lhsNode
					conditionNode.child[2] = rhsNode
				else
					conditionNode = extraConditionNode
				end
			end

			-- Create "if" node.
			if conditionNode then
				node = OvaleAST:NewNode(nodeList, true)
				node.type = "if"
				node.child[1] = conditionNode
				node.child[2] = bodyNode
				if bodyNode.type == "simc_pool_resource" then
					node.simc_pool_resource = true
				elseif bodyNode.type == "simc_wait" then
					node.simc_wait = true
				end
			else
				node = bodyNode
			end
		end
	end

	return node
end

EmitActionList = function(parseNode, nodeList, annotation)
	-- Function body is a group of statements.
	local groupNode = OvaleAST:NewNode(nodeList, true)
	groupNode.type = "group"
	local child = groupNode.child
	local poolResourceNode
	local emit = true
	for _, actionNode in ipairs(parseNode.child) do
		-- Add a comment containing the action to be translated.
		local commentNode = OvaleAST:NewNode(nodeList)
		commentNode.type = "comment"
		commentNode.comment = actionNode.action
		child[#child + 1] = commentNode
		if emit then
			-- Add the translated statement.
			local statementNode = EmitAction(actionNode, nodeList, annotation)
			if statementNode then
				if statementNode.type == "simc_pool_resource" then
					local powerType = OvalePower.POOLED_RESOURCE[annotation.class]
					if powerType then
						if statementNode.for_next then
							poolResourceNode = statementNode
							poolResourceNode.powerType = powerType
						else
							-- This is a bare "pool_resource" statement, which means pool
							-- continually and skip the rest of the action list.
							emit = false
						end
					end
				elseif poolResourceNode then
					-- This is the action following "pool_resource,for_next=1".
					child[#child + 1] = statementNode
					local powerType = CamelCase(poolResourceNode.powerType)
					local extra_amount = poolResourceNode.extra_amount
					if extra_amount then
						local commentNode = OvaleAST:NewNode(nodeList)
						commentNode.type = "comment"
						commentNode.comment = format("Remove any '%s() >= %d' condition from the following statement.", powerType, extra_amount)
						child[#child + 1] = commentNode
					end
					if statementNode.type == "if" or statementNode.type == "unless" then
						local bodyNode = statementNode.child[2]
						if bodyNode.type == "action" and bodyNode.rawParams and bodyNode.rawParams[1] then
							local name = OvaleAST:Unparse(bodyNode.rawParams[1])
							-- Create a condition node that includes checking that the spell is not on cooldown.
							local powerCondition
							if extra_amount then
								powerCondition = format("TimeTo%s(%d)", powerType, extra_amount)
							else
								powerCondition = format("TimeTo%sFor(%s)", powerType, name)
							end
							local code = format("SpellUsable(%s) and SpellCooldown(%s) < %s", name, name, powerCondition)
							local conditionNode = OvaleAST:NewNode(nodeList, true)
							conditionNode.type = "logical"
							conditionNode.expressionType = "binary"
							conditionNode.operator = "and"
							conditionNode.child[1] = statementNode.child[1]
							conditionNode.child[2] = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
							-- Create node to hold the rest of the statements.
							local restNode = OvaleAST:NewNode(nodeList, true)
							child[#child + 1] = restNode
							if statementNode.type == "if" then
								restNode.type = "unless"
							elseif statementNode.type == "unless" then
								restNode.type = "if"
							end
							restNode.child[1] = conditionNode
							restNode.child[2] = OvaleAST:NewNode(nodeList, true)
							restNode.child[2].type = "group"
							child = restNode.child[2].child
						end
					else
						-- We are pooling for this action, but it has no condition, which means
						-- pool continually and skip the rest of the action list.
						emit = false
					end
					poolResourceNode = nil
				elseif statementNode.type == "simc_wait" then
					-- This is a bare "wait" statement, which we don't know how to process, so
					-- skip it.
				elseif statementNode.simc_wait then
					-- Create an "unless" node with the remaining statements as the body.
					local restNode = OvaleAST:NewNode(nodeList, true)
					child[#child + 1] = restNode
					restNode.type = "unless"
					restNode.child[1] = statementNode.child[1]
					restNode.child[2] = OvaleAST:NewNode(nodeList, true)
					restNode.child[2].type = "group"
					child = restNode.child[2].child
				else
					child[#child + 1] = statementNode
					if statementNode.simc_pool_resource then
						-- Flip the "if/unless" statement and change the body into a group node
						-- containing all of the rest of the statements.
						if statementNode.type == "if" then
							statementNode.type = "unless"
						elseif statementNode.type == "unless" then
							statementNode.type = "if"
						end
						statementNode.child[2] = OvaleAST:NewNode(nodeList, true)
						statementNode.child[2].type = "group"
						child = statementNode.child[2].child
					end
				end
			end
		end
	end

	local node = OvaleAST:NewNode(nodeList, true)
	node.type = "add_function"
	node.name = OvaleFunctionName(parseNode.name, annotation)
	node.child[1] = groupNode
	return node
end

EmitExpression = function(parseNode, nodeList, annotation, action)
	local node
	local msg
	if parseNode.expressionType == "unary" then
		local opInfo = UNARY_OPERATOR[parseNode.operator]
		if opInfo then
			local operator
			if parseNode.operator == "!" then
				operator = "not"
			elseif parseNode.operator == "-" then
				operator = parseNode.operator
			end
			if operator then
				local rhsNode = Emit(parseNode.child[1], nodeList, annotation, action)
				if rhsNode then
					if operator == "-" and rhsNode.type == "value" then
						rhsNode.value = -1 * rhsNode.value
					else
						node = OvaleAST:NewNode(nodeList, true)
						node.type = opInfo[1]
						node.expressionType = "unary"
						node.operator = operator
						node.precedence = opInfo[2]
						node.child[1] = rhsNode
					end
				end
			end
		end
	elseif parseNode.expressionType == "binary" then
		local opInfo = BINARY_OPERATOR[parseNode.operator]
		if opInfo then
			local operator
			if parseNode.operator == "&" then
				operator = "and"
			elseif parseNode.operator == "^" then
				operator = "xor"
			elseif parseNode.operator == "|" then
				operator = "or"
			elseif parseNode.operator == "=" then
				operator = "=="
			elseif parseNode.operator == "%" then
				operator = "/"
			elseif parseNode.type == "compare" or parseNode.type == "arithmetic" then
				operator = parseNode.operator
			end
			if parseNode.type == "compare" and parseNode.child[1].rune then
				--[[
					Special handling for rune comparisons.
					This ONLY handles rune expressions of the form "<rune><operator><number>".
					These are translated to equivalent "Rune(<rune>) <operator> <number>" expressions,
					but with some munging of the numbers since Rune() returns a fractional number of runes.
				--]]
				local lhsNode = parseNode.child[1]
				local rhsNode = parseNode.child[2]
				local runeType = lhsNode.rune
				local number = (rhsNode.type == "number") and tonumber(Unparse(rhsNode)) or nil
				if rhsNode.type == "number" then
					number = tonumber(Unparse(rhsNode))
				end
				if runeType and number then
					local code
					local op = parseNode.operator
					if op == ">" then
						code = format("Rune(%s) >= %d", runeType, number + 1)
					elseif op == ">=" then
						code = format("Rune(%s) >= %d", runeType, number)
					elseif op == "=" then
						if runeType ~= "death" and number == 2 then
							-- We can never have more than 2 non-death runes of the same type.
							code = format("Rune(%s) >= %d", runeType, number)
						else
							code = format("Rune(%s) >= %d and Rune(%s) < %d", runeType, number, runeType, number + 1)
						end
					elseif op == "<=" then
						code = format("Rune(%s) < %d", runeType, number + 1)
					elseif op == "<" then
						code = format("Rune(%s) < %d", runeType, number)
					end
					if not node and code then
						annotation.astAnnotation = annotation.astAnnotation or {}
						node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
					end
				end
			elseif (parseNode.operator == "=" or parseNode.operator == "!=")
					and (parseNode.child[1].name == "target" or parseNode.child[1].name == "current_target") then
				--[[
					Special handling for "target=X" or "current_target=X" expressions.
					TODO: This whole section will need to be updated once Prismatic Crystals can be summoned.
				--]]
				local lhsNode = parseNode.child[1]
				local rhsNode = parseNode.child[2]
				local name = rhsNode.name
				if name == "prismatic_crystal" then
					name = '"Prismatic Crystal"'
				end
				local code
				if parseNode.operator == "=" then
					code = format("target.Name(%s)", name)
				else -- if parseNode.operator == "!=" then
					code = format("not target.Name(%s)", name)
				end
				if not node and code then
					annotation.astAnnotation = annotation.astAnnotation or {}
					node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
				end
			elseif operator then
				local lhsNode = Emit(parseNode.child[1], nodeList, annotation, action)
				local rhsNode = Emit(parseNode.child[2], nodeList, annotation, action)
				if lhsNode and rhsNode then
					node = OvaleAST:NewNode(nodeList, true)
					node.type = opInfo[1]
					node.expressionType = "binary"
					node.operator = operator
					node.precedence = opInfo[2]
					node.child[1] = lhsNode
					node.child[2] = rhsNode
				elseif lhsNode then
					msg = Ovale:Format("Warning: %s operator '%s' right failed.", parseNode.type, parseNode.operator)
				elseif rhsNode then
					msg = Ovale:Format("Warning: %s operator '%s' left failed.", parseNode.type, parseNode.operator)
				else
					msg = Ovale:Format("Warning: %s operator '%s' left and right failed.", parseNode.type, parseNode.operator)
				end
			end
		end
	end
	if node then
		if parseNode.left and parseNode.right then
			node.left = "{"
			node.right = "}"
		end
	else
		msg = msg or Ovale:Format("Warning: Operator '%s' is not implemented.", parseNode.operator)
		Ovale:Print(msg)
		node = OvaleAST:NewNode(nodeList)
		node.type = "string"
		node.value = "FIXME_" .. parseNode.operator
	end
	return node
end

EmitFunction = function(parseNode, nodeList, annotation, action)
	local node
	if parseNode.name == "ceil" then
		-- Pretend ceil(expression) = expression.
		node = EmitExpression(parseNode.child[1], nodeList, annotation, action)
	else
		Ovale:FormatPrint("Warning: Function '%s' is not implemented.", parseNode.name)
		node = OvaleAST:NewNode(nodeList)
		node.type = "variable"
		node.name = "FIXME_" .. parseNode.name
	end
	return node
end

EmitModifier = function(modifier, parseNode, nodeList, annotation, action)
	local node, code
	local class = annotation.class
	local specialization = annotation.specialization

	if modifier == "if" then
		node = Emit(parseNode, nodeList, annotation, action)
	elseif modifier == "line_cd" then
		if not SPECIAL_ACTION[action] then
			local value = tonumber(Unparse(parseNode))
			AddSymbol(annotation, action)
			code = format("TimeSincePreviousSpell(%s) > %d", action, value)
		end
	elseif modifier == "max_cycle_targets" then
		local value = tonumber(Unparse(parseNode))
		local debuffName = action .. "_debuff"
		AddSymbol(annotation, debuffName)
		code = format("DebuffCountOnAny(%s) <= Enemies() and DebuffCountOnAny(%s) <= %d", debuffName, debuffName, value)
	elseif modifier == "moving" then
		local value = tonumber(Unparse(parseNode))
		if value == 1 then
			code = "Speed() > 0"
		end
	elseif modifier == "sync" then
		local name = Unparse(parseNode)
		name = Disambiguate(name, class, specialization)
		AddSymbol(annotation, name)
		code = format("not SpellCooldown(%s) > 0", name)
	end
	if not node and code then
		annotation.astAnnotation = annotation.astAnnotation or {}
		node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
	end
	return node
end

EmitNumber = function(parseNode, nodeList, annotation, action)
	local node = OvaleAST:NewNode(nodeList)
	node.type = "value"
	node.value = parseNode.value
	node.origin = 0
	node.rate = 0
	return node
end

EmitOperand = function(parseNode, nodeList, annotation, action)
	local ok = false
	local node

	local operand = parseNode.name
	local token = strmatch(operand, OPERAND_TOKEN_PATTERN)	-- peek
	local target
	if token == "target" then
		target = token
		operand = strsub(operand, strlen(target) + 2)		-- consume
		token = strmatch(operand, OPERAND_TOKEN_PATTERN)	-- peek
	end
	ok, node = EmitOperandRune(operand, parseNode, nodeList, annotation, action)
	if not ok then
		ok, node = EmitOperandSpecial(operand, parseNode, nodeList, annotation, action, target)
	end
	if not ok then
		ok, node = EmitOperandRaidEvent(operand, parseNode, nodeList, annotation, action)
	end
	if not ok then
		ok, node = EmitOperandAction(operand, parseNode, nodeList, annotation, action, target)
	end
	if not ok then
		ok, node = EmitOperandCharacter(operand, parseNode, nodeList, annotation, action, target)
	end
	if not ok then
		if token == "active_dot" then
			target = target or "target"
			ok, node = EmitOperandActiveDot(operand, parseNode, nodeList, annotation, action, target)
		elseif token == "aura" then
			ok, node = EmitOperandBuff(operand, parseNode, nodeList, annotation, action, target)
		elseif token == "buff" then
			ok, node = EmitOperandBuff(operand, parseNode, nodeList, annotation, action, target)
		elseif token == "cooldown" then
			ok, node = EmitOperandCooldown(operand, parseNode, nodeList, annotation, action)
		elseif token == "debuff" then
			target = target or "target"
			ok, node = EmitOperandBuff(operand, parseNode, nodeList, annotation, action, target)
		elseif token == "disease" then
			target = target or "target"
			ok, node = EmitOperandDisease(operand, parseNode, nodeList, annotation, action, target)
		elseif token == "dot" then
			target = target or "target"
			ok, node = EmitOperandDot(operand, parseNode, nodeList, annotation, action, target)
		elseif token == "glyph" then
			ok, node = EmitOperandGlyph(operand, parseNode, nodeList, annotation, action)
		elseif token == "pet" then
			ok, node = EmitOperandPet(operand, parseNode, nodeList, annotation, action)
		elseif token == "seal" then
			ok, node = EmitOperandSeal(operand, parseNode, nodeList, annotation, action)
		elseif token == "set_bonus" then
			ok, node = EmitOperandSetBonus(operand, parseNode, nodeList, annotation, action)
		elseif token == "talent" then
			ok, node = EmitOperandTalent(operand, parseNode, nodeList, annotation, action)
		elseif token == "totem" then
			ok, node = EmitOperandTotem(operand, parseNode, nodeList, annotation, action)
		elseif token == "trinket" then
			ok, node = EmitOperandTrinket(operand, parseNode, nodeList, annotation, action)
		end
	end
	if not ok then
		node = OvaleAST:NewNode(nodeList)
		node.type = "variable"
		node.name = "FIXME_" .. parseNode.name
	end

	return node
end

EmitOperandAction = function(operand, parseNode, nodeList, annotation, action, target)
	local ok = true
	local node

	local name
	local property
	if strsub(operand, 1, 7) == "action." then
		local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
		local token = tokenIterator()
		name = tokenIterator()
		property = tokenIterator()
	else
		name = action
		property = operand
	end

	name = Disambiguate(name, annotation.class, annotation.specialization)
	target = target and (target .. ".") or ""
	local buffName = name .. "_debuff"
	buffName = Disambiguate(buffName, annotation.class, annotation.specialization)
	local prefix = strfind(buffName, "_buff$") and "Buff" or "Debuff"
	local buffTarget = (prefix == "Debuff") and "target." or target
	local talentName = name .. "_talent"
	talentName = Disambiguate(talentName, annotation.class, annotation.specialization)
	local symbol = name

	local code
	if property == "active" then
		if strsub(name, -6) == "_totem" then
			local totemType = TOTEM_TYPE[name]
			if totemType then
				code = format("TotemPresent(%s totem=%s)", totemType, name)
			else
				code = format("TotemPresent(%s)", name)
				symbol = false
			end
		else
			code = format("%s%sPresent(%s)", target, prefix, buffName)
			symbol = buffName
		end
	elseif property == "cast_regen" then
		code = format("FocusCastingRegen(%s)", name)
	elseif property == "cast_time" then
		code = format("CastTime(%s)", name)
	elseif property == "charges" then
		code = format("Charges(%s)", name)
	elseif property == "charges_fractional" then
		code = format("Charges(%s count=0)", name)
	elseif property == "cooldown" then
		code = format("SpellCooldown(%s)", name)
	elseif property == "cooldown_react" then
		code = format("not SpellCooldown(%s) > 0", name)
	elseif property == "duration" then
		code = format("BaseDuration(%s)", buffName)
		symbol = buffName
	elseif property == "enabled" then
		code = format("Talent(%s)", talentName)
		symbol = talentName
	elseif property == "execute_time" then
		code = format("ExecuteTime(%s)", name)
	elseif property == "gcd" then
		code = "GCD()"
	elseif property == "in_flight" or property == "in_flight_to_target" then
		code = format("InFlightToTarget(%s)", name)
	elseif property == "miss_react" then
		-- "miss_react" has no meaning in Ovale.
		code = "True(miss_react)"
	elseif property == "persistent_multiplier" then
		code = format("DamageMultiplier(%s)", name)
	elseif property == "recharge_time" then
		code = format("SpellChargeCooldown(%s)", name)
	elseif property == "remains" then
		if strsub(name, -6) == "_totem" then
			local totemType = TOTEM_TYPE[name]
			if totemType then
				code = format("TotemRemaining(%s totem=%s)", totemType, name)
			else
				code = format("TotemRemaining(%s)", name)
				symbol = false
			end
		else
			code = format("%s%sRemaining(%s)", buffTarget, prefix, buffName)
			symbol = buffName
		end
	elseif property == "shard_react" then
		-- XXX
		code = "SoulShards() >= 1"
	elseif property == "tick_time" then
		code = format("%sTickTime(%s)", buffTarget, buffName)
		symbol = buffName
	elseif property == "ticking" then
		code = format("%s%sPresent(%s)", buffTarget, prefix, buffName)
		symbol = buffName
	elseif property == "ticks_remain" then
		code = format("%sTicksRemaining(%s)", buffTarget, buffName)
		symbol = buffName
	elseif property == "travel_time" then
		-- Translate to the maximum travel time since we can't gauge the distance dynamically.
		code = format("MaxTravelTime(%s)", name)
	else
		ok = false
	end
	if ok and code then
		annotation.astAnnotation = annotation.astAnnotation or {}
		node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
		if symbol then
			AddSymbol(annotation, symbol)
		end
	end

	return ok, node
end

EmitOperandActiveDot = function(operand, parseNode, nodeList, annotation, action, target)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "active_dot" then
		local name = tokenIterator()
		name = Disambiguate(name, annotation.class, annotation.specialization)
		local dotName = name .. "_debuff"
		dotName = Disambiguate(dotName, annotation.class, annotation.specialization)
		local prefix = strfind(dotName, "_buff$") and "Buff" or "Debuff"
		target = target and (target .. ".") or ""

		local code = format("%sCountOnAny(%s)", prefix, dotName)
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, dotName)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandBuff = function(operand, parseNode, nodeList, annotation, action, target)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "aura" or token == "buff" or token == "debuff" then
		local name = tokenIterator()
		local property = tokenIterator()
		name = Disambiguate(name, annotation.class, annotation.specialization)
		local buffName = (token == "debuff") and name .. "_debuff" or name .. "_buff"
		buffName = Disambiguate(buffName, annotation.class, annotation.specialization)
		local prefix = strfind(buffName, "_buff$") and "Buff" or "Debuff"
		local any = OvaleData.buffSpellList[buffName] and " any=1" or ""
		target = target and (target .. ".") or ""

		-- Unholy death knight's Dark Transformation applies the buff to the ghoul/pet.
		if buffName == "dark_transformation_buff" then
			if target == "" then
				target = "pet."
			end
			any = " any=1"
		end

		-- Assume that the "potion" action has already been seen.
		if buffName == "potion_buff" then
			if annotation.use_potion_agility then
				buffName = "potion_agility_buff"
			elseif annotation.use_potion_armor then
				buffName = "potion_armor_buff"
			elseif annotation.use_potion_intellect then
				buffName = "potion_intellect_buff"
			elseif annotation.use_potion_strength then
				buffName = "potion_strength_buff"
			end
		end

		local code
		if property == "cooldown_remains" then
			-- Assume that the spell and the buff have the same name.
			code = format("SpellCooldown(%s)", name)
		elseif property == "down" then
			code = format("%s%sExpires(%s%s)", target, prefix, buffName, any)
		elseif property == "duration" then
			code = format("BaseDuration(%s)", buffName)
		elseif property == "max_stack" then
			code = format("SpellData(%s max_stacks)", buffName)
		elseif property == "react" or property == "stack" then
			if parseNode.asType == "boolean" then
				code = format("%s%sPresent(%s%s)", target, prefix, buffName, any)
			else
				code = format("%s%sStacks(%s%s)", target, prefix, buffName, any)
			end
		elseif property == "remains" then
			if parseNode.asType == "boolean" then
				code = format("%s%sPresent(%s%s)", target, prefix, buffName, any)
			else
				code = format("%s%sRemaining(%s%s)", target, prefix, buffName, any)
			end
		elseif property == "up" then
			code = format("%s%sPresent(%s%s)", target, prefix, buffName, any)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, buffName)
		end
	else
		ok = false
	end

	return ok, node
end

do
	local CHARACTER_PROPERTY = {
		["active_enemies"]		= "Enemies()",
		["blood.frac"]			= "Rune(blood)",
		["chi"]					= "Chi()",
		["chi.max"]				= "MaxChi()",
		["combo_points"]		= "ComboPoints()",
		["demonic_fury"]		= "DemonicFury()",
		["eclipse_change"]		= "TimeToEclipse()",	-- XXX
		["eclipse_energy"]		= "EclipseEnergy()",	-- XXX
		["energy"]				= "Energy()",
		["energy.max"]			= "MaxEnergy()",
		["energy.regen"]		= "EnergyRegenRate()",
		["energy.time_to_max"]	= "TimeToMaxEnergy()",
		["focus"]				= "Focus()",
		["focus.deficit"]		= "FocusDeficit()",
		["focus.regen"]			= "FocusRegenRate()",
		["focus.time_to_max"]	= "TimeToMaxFocus()",
		["frost.frac"]			= "Rune(frost)",
		["health"]				= "Health()",
		["health.deficit"]		= "HealthMissing()",
		["health.max"]			= "MaxHealth()",
		["health.pct"]			= "HealthPercent()",
		["health.percent"]		= "HealthPercent()",
		["holy_power"]			= "HolyPower()",
		["level"]				= "Level()",
		["lunar_max"]			= "TimeToEclipse(lunar)",	-- XXX
		["mana"]				= "Mana()",
		["mana.deficit"]		= "ManaDeficit()",
		["mana.max"]			= "MaxMana()",
		["mana.pct"]			= "ManaPercent()",
		["rage"]				= "Rage()",
		["rage.max"]			= "MaxRage()",
		["runic_power"]			= "RunicPower()",
		["shadow_orb"]			= "ShadowOrbs()",
		["soul_shard"]			= "SoulShards()",
		["stat.multistrike_pct"]= "MultistrikeChance()",
		["time"]				= "TimeInCombat()",
		["time_to_die"]			= "TimeToDie()",
		["unholy.frac"]			= "Rune(unholy)",
	}

	EmitOperandCharacter = function(operand, parseNode, nodeList, annotation, action, target)
		local ok = true
		local node

		local class = annotation.class
		local specialization = annotation.specialization

		target = target and (target .. ".") or ""
		local code
		if CHARACTER_PROPERTY[operand] then
			code = target .. CHARACTER_PROPERTY[operand]
		elseif class == "MAGE" and operand == "incanters_flow_dir" then
			local name = "incanters_flow_buff"
			code = format("BuffDirection(%s)", name)
			AddSymbol(annotation, name)
		elseif class == "PALADIN" and operand == "time_to_hpg" then
			if specialization == "holy" then
				code = "HolyTimeToHPG()"
				annotation.time_to_hpg_heal = class
			elseif specialization == "protection" then
				code = "ProtectionTimeToHPG()"
				annotation.time_to_hpg_tank = class
			elseif specialization == "retribution" then
				code = "RetributionTimeToHPG()"
				annotation.time_to_hpg_melee = class
			end
		elseif class == "ROGUE" and operand == "anticipation_charges" then
			local name = "anticipation_buff"
			code = format("BuffStacks(%s)", name)
			AddSymbol(annotation, name)
		elseif class == "WARLOCK" and operand == "burning_ember" then
			code = format("%sBurningEmbers() / 10", target)
		elseif strfind(operand, "^incoming_damage_") then
			local seconds, measure = strmatch(operand, "^incoming_damage_([%d]+)(m?s?)$")
			seconds = tonumber(seconds)
			if measure == "ms" then
				seconds = seconds / 1000
			end
			if parseNode.asType == "boolean" then
				code = format("IncomingDamage(%f) > 0", seconds)
			else
				code = format("IncomingDamage(%f)", seconds)
			end
		elseif operand == "mastery_value" then
			code = format("%sMasteryEffect() / 100", target)
		elseif operand == "position_front" then
			-- "position_front" should always be false in Ovale because we assume the
			-- player can get into the optimal attack position at all times.
			code = "False(position_front)"
		elseif strsub(operand, 1, 5) == "role." then
			local role = strmatch(operand, "^role%.([%w_]+)")
			if role and role == annotation.role then
				code = format("True(role_%s)", role)
			else
				code = format("False(role_%s)", role)
			end
		elseif operand == "spell_haste" or operand == "stat.spell_haste" then
			code = format("%sSpellHaste() / 100", target)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
		end

		return ok, node
	end
end

EmitOperandCooldown = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "cooldown" then
		local name = tokenIterator()
		local property = tokenIterator()
		name = Disambiguate(name, annotation.class, annotation.specialization)
		local prefix = "Spell"

		-- Assume that the "potion" action has already been seen.
		if name == "potion" then
			prefix = "Item"
			if annotation.use_potion_agility then
				name = "virmens_bite_potion"
			elseif annotation.use_potion_armor then
				name = "mountains_potion"
			elseif annotation.use_potion_intellect then
				name = "jade_serpent_potion"
			elseif annotation.use_potion_strength then
				name = "mogu_power_potion"
			end
		end

		local code
		if property == "duration" then
			code = format("%sCooldownDuration(%s)", prefix, name)
		elseif property == "remains" then
			if parseNode.asType == "boolean" then
				code = format("%sCooldown(%s) > 0", prefix, name)
			else
				code = format("%sCooldown(%s)", prefix, name)
			end
		elseif property == "up" then
			code = format("not %sCooldown(%s) > 0", prefix, name)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, name)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandDisease = function(operand, parseNode, nodeList, annotation, action, target)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "disease" then
		local property = tokenIterator()
		target = target and (target .. ".") or ""

		local code
		if property == "max_ticking" then
			code = target .. "DiseasesAnyTicking()"
		elseif property == "min_remains" then
			code = target .. "DiseasesRemaining()"
		elseif property == "min_ticking" then
			code = target .. "DiseasesTicking()"
		elseif property == "ticking" then
			code = target .. "DiseasesAnyTicking()"
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandDot = function(operand, parseNode, nodeList, annotation, action, target)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "dot" then
		local name = tokenIterator()
		local property = tokenIterator()
		name = Disambiguate(name, annotation.class, annotation.specialization)
		local dotName = name .. "_debuff"
		dotName = Disambiguate(dotName, annotation.class, annotation.specialization)
		local prefix = strfind(dotName, "_buff$") and "Buff" or "Debuff"
		target = target and (target .. ".") or ""

		local code
		if property == "duration" then
			code = format("%s%sDuration(%s)", target, prefix, dotName)
		elseif property == "pmultiplier" then
			code = format("%s%sDamageMultiplier(%s)", target, prefix, dotName)
		elseif property == "remains" then
			code = format("%s%sRemaining(%s)", target, prefix, dotName)
		elseif property == "stack" then
			code = format("%s%sStacks(%s)", target, prefix, dotName)
		elseif property == "ticking" then
			code = format("%s%sPresent(%s)", target, prefix, dotName)
		elseif property == "ticks_remain" then
			code = format("%sTicksRemaining(%s)", target, dotName)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, dotName)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandGlyph = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "glyph" then
		local name = tokenIterator()
		local property = tokenIterator()
		name = Disambiguate(name, annotation.class, annotation.specialization)
		local glyphName = "glyph_of_" .. name
		glyphName = Disambiguate(glyphName, annotation.class, annotation.specialization)

		local code
		if property == "disabled" then
			code = format("not Glyph(%s)", glyphName)
		elseif property == "enabled" then
			code = format("Glyph(%s)", glyphName)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, glyphName)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandPet = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "pet" then
		local name = tokenIterator()
		local property = tokenIterator()
		name = Disambiguate(name, annotation.class, annotation.specialization)
		local totemType = TOTEM_TYPE[name]

		local code
		if property == "active" then
			if totemType then
				code = format("TotemPresent(%s totem=%s)", totemType, name)
			else
				code = format("TotemPresent(%s)", name)
			end
		elseif property == "remains" then
			if totemType then
				code = format("TotemRemaining(%s totem=%s)", totemType, name)
			else
				code = format("TotemRemaining(%s)", name)
			end
		else
			-- Strip the "pet.<name>." from the operand and re-evaluate.
			local pattern = format("^pet%%.%s%%.([%%w_.]+)", name)
			local petOperand = strmatch(operand, pattern)
			local target = "pet"
			if petOperand then
				ok, node = EmitOperandSpecial(petOperand, parseNode, nodeList, annotation, action, target)
				if not ok then
					ok, node = EmitOperandAction(petOperand, parseNode, nodeList, annotation, action, target)
				end
				if not ok then
					ok, node = EmitOperandCharacter(petOperand, parseNode, nodeList, annotation, action, target)
				end
				if not ok then
					if property == "buff" then
						ok, node = EmitOperandBuff(petOperand, parseNode, nodeList, annotation, action, target)
					elseif token == "debuff" then
						ok, node = EmitOperandBuff(petOperand, parseNode, nodeList, annotation, action, target)
					else
						ok = false
					end
				end
			else
				ok = false
			end
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			if totemType then
				AddSymbol(annotation, name)
			end
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandRaidEvent = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local name
	local property
	if strsub(operand, 1, 11) == "raid_event." then
		local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
		local token = tokenIterator()
		name = tokenIterator()
		property = tokenIterator()
	else
		local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
		name = tokenIterator()
		property = tokenIterator()
	end

	local code
	if name == "movement" then
		--[[
			The "movement" raid event simulates needing to move during the encounter.
			We always assume the fight is Patchwerk-style, meaning no movement is
			necessary.
		--]]
		if property == "cooldown" or property == "in" then
			-- Pretend the next "movement" raid event is ten minutes from now.
			code = "600"
		elseif property == "distance" then
			code = "0"
		elseif property == "exists" then
			code = "False(raid_event_movement_exists)"
		elseif property == "remains" then
			code = "0"
		else
			ok = false
		end
	elseif name == "adds" then
		--[[
			The "adds" raid event simulates waves of adds on regular intervals.
			This is separate from the dynamic number of active enemies.
			We always assume that there are no add waves.
		--]]
		if property == "cooldown" then
			-- Pretend the next "adds" raid event is ten minutes from now.
			code = "600"
		elseif property == "count" then
			code = "0"
		elseif property == "exists" then
			code = "False(raid_event_adds_exists)"
		else
			ok = false
		end
	else
		ok = false
	end
	if ok and code then
		annotation.astAnnotation = annotation.astAnnotation or {}
		node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
	end

	return ok, node
end

EmitOperandRune = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local code
	if parseNode.rune then
		if parseNode.asType == "boolean" then
			code = format("Rune(%s) >= 1", parseNode.rune)
		else
			code = format("RuneCount(%s)", parseNode.rune)
		end
	else
		ok = false
	end
	if ok and code then
		annotation.astAnnotation = annotation.astAnnotation or {}
		node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
	end

	return ok, node
end

EmitOperandSetBonus = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local setBonus = strmatch(operand, "^set_bonus%.(.*)$")
	local code
	if setBonus then
		local tokenIterator = gmatch(setBonus, "[^_]+")
		local name = tokenIterator()
		local count = tokenIterator()
		local role = tokenIterator()
		if name and count then
			local setName, level = strmatch(name, "^(%a+)(%d*)$")
			if setName == "tier" then
				setName = "T"
			else
				setName = strupper(setName)
			end
			if level then
				name = setName .. tostring(level)
			end
			if role then
				name = name .. "_" .. role
			end
			count = strmatch(count, "(%d+)pc")
			if name and count then
				code = format("ArmorSetBonus(%s %d)", name, count)
			end
		end
		if not code then
			ok = false
		end
	else
		ok = false
	end
	if ok and code then
		annotation.astAnnotation = annotation.astAnnotation or {}
		node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
	end

	return ok, node
end

EmitOperandSeal = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "seal" then
		local name = tokenIterator()
		local code
		if name then
			code = format("Stance(paladin_seal_of_%s)", name)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandSpecial = function(operand, parseNode, nodeList, annotation, action, target)
	local ok = true
	local node

	local class = annotation.class
	local specialization = annotation.specialization

	target = target and (target .. ".") or ""
	local code
	if class == "DEATHKNIGHT" and operand == "dot.breath_of_sindragosa.ticking" then
		-- Breath of Sindragosa is the player buff from channeling the spell.
		local buffName = "breath_of_sindragosa_buff"
		code = format("BuffPresent(%s)", buffName)
		AddSymbol(annotation, buffName)
	elseif class == "DEATHKNIGHT" and strsub(operand, -9, -1) == ".ready_in" then
		local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
		local spellName = tokenIterator()
		spellName = Disambiguate(spellName, class, specialization)
		code = format("TimeToSpell(%s)", spellName)
		AddSymbol(annotation, spellName)
	elseif class == "DRUID" and operand == "max_fb_energy" then
		-- SimulationCraft's max_fb_energy is the maximum cost of Ferocious Bite if used.
		local spellName = "ferocious_bite"
		code = format("EnergyCost(%s max=1)", spellName)
		AddSymbol(annotation, spellName)
	elseif class == "HUNTER" and operand == "buff.beast_cleave.down" then
		-- Beast Cleave is a buff on the hunter's pet.
		local buffName = "pet_beast_cleave_buff"
		code = format("pet.BuffExpires(%s any=1)", buffName)
		AddSymbol(annotation, buffName)
	elseif class == "HUNTER" and operand == "buff.careful_aim.up" then
		-- The "careful_aim" buff is a fake SimulationCraft buff.
		code = format("%sHealthPercent() > 80 or BuffPresent(rapid_fire_buff)", target)
		AddSymbol(annotation, "rapid_fire_buff")
	elseif class == "MAGE" and operand == "buff.rune_of_power.remains" then
		code = "RuneOfPowerRemaining()"
	elseif class == "MAGE" and operand == "dot.frozen_orb.ticking" then
		-- The Frozen Orb is ticking if fewer than 10s have elapsed since it was cast.
		local name = "frozen_orb"
		code = format("SpellCooldown(%s) > SpellCooldownDuration(%s) - 10", name, name)
		AddSymbol(annotation, name)
	elseif class == "MAGE" and operand == "pyro_chain" then
		if parseNode.asType == "boolean" then
			code = "GetState(pyro_chain) > 0"
		else
			code = "GetState(pyro_chain)"
		end
	elseif class == "MONK" and operand == "dot.zen_sphere.ticking" then
		-- Zen Sphere is a helpful DoT.
		local buffName = "zen_sphere_buff"
		code = format("BuffPresent(%s)", buffName)
		AddSymbol(annotation, buffName)
	elseif class == "MONK" and (operand == "stagger.heavy" or operand == "stagger.light" or operand == "stagger.moderate") then
		local property = strmatch(operand, "^stagger%.(%w+)")
		local buffName = format("%s_stagger_debuff", property)
		code = format("DebuffPresent(%s)", buffName)
		AddSymbol(annotation, buffName)
	elseif class == "PALADIN" and operand == "dot.sacred_shield.remains" then
		--[[
			Sacred Shield is handled specially because SimulationCraft treats it like
			a damaging spell, e.g., "target.dot.sacred_shield.remains" to represent the
			buff on the player.
		--]]
		local buffName = "sacred_shield_buff"
		code = format("BuffPresent(%s)", buffName)
		AddSymbol(annotation, buffName)
	elseif class == "PRIEST" and operand == "mind_harvest" then
		-- TODO: "mind_harvest" on the current target is 0 if no Mind Blast has been cast on the target yet.
		code = "0"
	elseif class == "PRIEST" and operand == "primary_target" then
		-- TODO: "primary_target" is 1 if the current target is the "main/boss" target.
		code = "0"
	elseif operand == "debuff.casting.react" then
		code = target .. "IsInterruptible()"
	elseif operand == "debuff.flying.down" then
		code = target .. "True(debuff_flying_down)"
	elseif operand == "distance" then
		code = target .. "Distance()"
	elseif operand == "gcd.max" then
		code = "GCD()"
	else
		ok = false
	end
	if ok and code then
		annotation.astAnnotation = annotation.astAnnotation or {}
		node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
	end

	return ok, node
end

EmitOperandTalent = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "talent" then
		local name = tokenIterator()
		local property = tokenIterator()
		-- Talent names need no disambiguation as they are the same across all specializations.
		--name = Disambiguate(name, annotation.class, annotation.specialization)
		local talentName = name .. "_talent"
		talentName = Disambiguate(talentName, annotation.class, annotation.specialization)

		local code
		if property == "disabled" then
			code = format("not Talent(%s)", talentName)
		elseif property == "enabled" then
			code = format("Talent(%s)", talentName)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, talentName)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandTotem = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "totem" then
		local name = tokenIterator()
		local property = tokenIterator()

		local code
		if property == "active" then
			code = format("TotemPresent(%s)", name)
		elseif property == "remains" then
			code = format("TotemRemaining(%s)", name)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
		end
	else
		ok = false
	end

	return ok, node
end

EmitOperandTrinket = function(operand, parseNode, nodeList, annotation, action)
	local ok = true
	local node

	local tokenIterator = gmatch(operand, OPERAND_TOKEN_PATTERN)
	local token = tokenIterator()
	if token == "trinket" then
		local procType = tokenIterator()
		local statName = tokenIterator()
		local property = tokenIterator()
		local buffName = format("trinket_%s_%s_buff", procType, statName)
		buffName = Disambiguate(buffName, annotation.class, annotation.specialization)

		local code
		if property == "cooldown_remains" then
			code = format("BuffCooldown(%s)", buffName)
		elseif property == "down" then
			code = format("BuffExpires(%s)", buffName)
		elseif property == "react" then
			if parseNode.asType == "boolean" then
				code = format("BuffPresent(%s)", buffName)
			else
				code = format("BuffStacks(%s)", buffName)
			end
		elseif property == "remains" then
			code = format("BuffRemaining(%s)", buffName)
		elseif property == "stack" then
			code = format("BuffStacks(%s)", buffName)
		elseif property == "up" then
			code = format("BuffPresent(%s)", buffName)
		else
			ok = false
		end
		if ok and code then
			annotation.astAnnotation = annotation.astAnnotation or {}
			node = OvaleAST:ParseCode("expression", code, nodeList, annotation.astAnnotation)
			AddSymbol(annotation, buffName)
		end
	else
		ok = false
	end

	return ok, node
end

do
	EMIT_VISITOR = {
		["action"] = EmitAction,
		["action_list"] = EmitActionList,
		["arithmetic"] = EmitExpression,
		["compare"] = EmitExpression,
		["function"] = EmitFunction,
		["logical"] = EmitExpression,
		["number"] = EmitNumber,
		["operand"] = EmitOperand,
	}
end

local function InsertSupportingFunctions(child, annotation)
	local count = 0
	local nodeList = annotation.astAnnotation.nodeList
	if annotation.mind_freeze == "DEATHKNIGHT" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					if target.InRange(mind_freeze) Spell(mind_freeze)
					if not target.Classification(worldboss)
					{
						if target.InRange(asphyxiate) Spell(asphyxiate)
						if target.InRange(strangulate) Spell(strangulate)
						Spell(arcane_torrent_runicpower)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_runicpower")
		AddSymbol(annotation, "asphyxiate")
		AddSymbol(annotation, "mind_freeze")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "strangulate")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.skull_bash == "DRUID" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					if target.InRange(skull_bash) Spell(skull_bash)
					if not target.Classification(worldboss)
					{
						if target.InRange(mighty_bash) Spell(mighty_bash)
						Spell(typhoon)
						if target.InRange(maim) Spell(maim)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "maim")
		AddSymbol(annotation, "mighty_bash")
		AddSymbol(annotation, "skull_bash")
		AddSymbol(annotation, "typhoon")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.melee == "DRUID" then
		local code = [[
			AddFunction GetInMeleeRange
			{
				if Stance(druid_bear_form) and not target.InRange(mangle)
				{
					if target.InRange(wild_charge_bear) Spell(wild_charge_bear)
					Texture(misc_arrowlup help=L(not_in_melee_range))
				}
				if Stance(druid_cat_form) and not target.InRange(shred)
				{
					if target.InRange(wild_charge_cat) Spell(wild_charge_cat)
					Texture(misc_arrowlup help=L(not_in_melee_range))
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "mangle")
		AddSymbol(annotation, "shred")
		AddSymbol(annotation, "wild_charge_bear")
		AddSymbol(annotation, "wild_charge_cat")
		count = count + 1
	end
	if annotation.summon_pet == "HUNTER" then
		local code = [[
			AddFunction SummonPet
			{
				if not pet.Present() Texture(ability_hunter_beastcall help=L(summon_pet))
				if pet.IsDead() Spell(revive_pet)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "revive_pet")
		count = count + 1
	end
	if annotation.counter_shot == "HUNTER" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					Spell(counter_shot)
					if not target.Classification(worldboss)
					{
						Spell(arcane_torrent_focus)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_focus")
		AddSymbol(annotation, "counter_shot")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.counterspell == "MAGE" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					Spell(counterspell)
					if not target.Classification(worldboss)
					{
						Spell(arcane_torrent_mana)
						if target.InRange(quaking_palm) Spell(quaking_palm)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_mana")
		AddSymbol(annotation, "counterspell")
		AddSymbol(annotation, "quaking_palm")
		count = count + 1
	end
	if annotation.spear_hand_strike == "MONK" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					if target.InRange(spear_hand_strike) Spell(spear_hand_strike)
					if not target.Classification(worldboss)
					{
						if target.InRange(paralysis) Spell(paralysis)
						Spell(arcane_torrent_chi)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_chi")
		AddSymbol(annotation, "paralysis")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "spear_hand_strike")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.time_to_hpg_melee == "PALADIN" then
		local code = [[
			AddFunction RetributionTimeToHPG
			{
				SpellCooldown(crusader_strike exorcism exorcism_glyphed hammer_of_wrath hammer_of_wrath_empowered judgment usable=1)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "crusader_strike")
		AddSymbol(annotation, "exorcism")
		AddSymbol(annotation, "exorcism_glyphed")
		AddSymbol(annotation, "hammer_of_wrath")
		AddSymbol(annotation, "judgment")
		count = count + 1
	end
	if annotation.time_to_hpg_tank == "PALADIN" then
		local code = [[
			AddFunction ProtectionTimeToHPG
			{
				if Talent(sanctified_wrath_talent) SpellCooldown(crusader_strike holy_wrath judgment)
				if not Talent(sanctified_wrath_talent) SpellCooldown(crusader_strike judgment)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "crusader_strike")
		AddSymbol(annotation, "holy_wrath")
		AddSymbol(annotation, "judgment")
		AddSymbol(annotation, "sanctified_wrath_talent")
		count = count + 1
	end
	if annotation.class == "PALADIN" then
		local code
		if annotation.specialization == "protection" then
			code = [[
				AddFunction ProtectionRighteousFury
				{
					if CheckBoxOn(opt_righteous_fury_check) and BuffExpires(righteous_fury) Spell(righteous_fury)
				}
			]]
		else
			code = [[
				AddFunction RighteousFuryOff
				{
					if CheckBoxOn(opt_righteous_fury_check) and BuffPresent(righteous_fury) Texture(spell_holy_sealoffury text=cancel)
				}
			]]
		end
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "righteous_fury")
		count = count + 1
	end
	if annotation.time_to_hpg_heal == "PALADIN" then
		local code = [[
			AddFunction HolyTimeToHPG
			{
				SpellCooldown(crusader_strike holy_shock judgment)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "crusader_strike")
		AddSymbol(annotation, "holy_shock")
		AddSymbol(annotation, "judgment")
		count = count + 1
	end
	if annotation.rebuke == "PALADIN" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					if target.InRange(rebuke) Spell(rebuke)
					if not target.Classification(worldboss)
					{
						if target.InRange(fist_of_justice) Spell(fist_of_justice)
						if target.InRange(hammer_of_justice) Spell(hammer_of_justice)
						Spell(blinding_light)
						Spell(arcane_torrent_holy)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_holy")
		AddSymbol(annotation, "blinding_light")
		AddSymbol(annotation, "fist_of_justice")
		AddSymbol(annotation, "hammer_of_justice")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "rebuke")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.melee == "PALADIN" then
		local code = [[
			AddFunction GetInMeleeRange
			{
				if not target.InRange(rebuke) Texture(misc_arrowlup help=L(not_in_melee_range))
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "rebuke")
		count = count + 1
	end
	if annotation.silence == "PRIEST" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					Spell(silence)
					if not target.Classification(worldboss)
					{
						Spell(arcane_torrent_mana)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_mana")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "silence")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.kick == "ROGUE" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					if target.InRange(kick) Spell(kick)
					if not target.Classification(worldboss)
					{
						if target.InRange(cheap_shot) Spell(cheap_shot)
						if target.InRange(deadly_throw) and ComboPoints() == 5 Spell(deadly_throw)
						if target.InRange(kidney_shot) Spell(kidney_shot)
						Spell(arcane_torrent_energy)
						if target.InRange(quaking_palm) Spell(quaking_palm)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_energy")
		AddSymbol(annotation, "cheap_shot")
		AddSymbol(annotation, "deadly_throw")
		AddSymbol(annotation, "kick")
		AddSymbol(annotation, "kidney_shot")
		AddSymbol(annotation, "quaking_palm")
		count = count + 1
	end
	if annotation.melee == "ROGUE" then
		local code = [[
			AddFunction GetInMeleeRange
			{
				if not target.InRange(kick)
				{
					Spell(shadowstep)
					Texture(misc_arrowlup help=L(not_in_melee_range))
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "kick")
		AddSymbol(annotation, "shadowstep")
		count = count + 1
	end
	if annotation.wind_shear == "SHAMAN" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					Spell(wind_shear)
					if not target.Classification(worldboss)
					{
						Spell(arcane_torrent_mana)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_mana")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "wind_shear")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.bloodlust == "SHAMAN" then
		local code = [[
			AddFunction Bloodlust
			{
				if CheckBoxOn(opt_bloodlust) and DebuffExpires(burst_haste_debuff any=1)
				{
					Spell(bloodlust)
					Spell(heroism)
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "bloodlust")
		AddSymbol(annotation, "heroism")
		count = count + 1
	end
	if annotation.pummel == "WARRIOR" then
		local code = [[
			AddFunction InterruptActions
			{
				if not target.IsFriend() and target.IsInterruptible()
				{
					if target.InRange(pummel) Spell(pummel)
					if Glyph(glyph_of_gag_order) and target.InRange(heroic_throw) Spell(heroic_throw)
					if not target.Classification(worldboss)
					{
						Spell(arcane_torrent_rage)
						if target.InRange(quaking_palm) Spell(quaking_palm)
						Spell(war_stomp)
					}
				}
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "arcane_torrent_rage")
		AddSymbol(annotation, "glyph_of_gag_order")
		AddSymbol(annotation, "heroic_throw")
		AddSymbol(annotation, "pummel")
		AddSymbol(annotation, "quaking_palm")
		AddSymbol(annotation, "war_stomp")
		count = count + 1
	end
	if annotation.melee == "WARRIOR" then
		local code = [[
			AddFunction GetInMeleeRange
			{
				if not target.InRange(pummel) Texture(misc_arrowlup help=L(not_in_melee_range))
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "pummel")
		count = count + 1
	end
	if annotation.use_item then
		local code = [[
			AddFunction UseItemActions
			{
				Item(HandSlot usable=1)
				Item(Trinket0Slot usable=1)
				Item(Trinket1Slot usable=1)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		count = count + 1
	end
	if annotation.use_potion_strength then
		local code = [[
			AddFunction UsePotionStrength
			{
				if CheckBoxOn(opt_potion_strength) and target.Classification(worldboss) Item(mogu_power_potion usable=1)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "mogu_power_potion")
		count = count + 1
	end
	if annotation.use_potion_intellect then
		local code = [[
			AddFunction UsePotionIntellect
			{
				if CheckBoxOn(opt_potion_intellect) and target.Classification(worldboss) Item(jade_serpent_potion usable=1)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "jade_serpent_potion")
		count = count + 1
	end
	if annotation.use_potion_armor then
		local code = [[
			AddFunction UsePotionArmor
			{
				if CheckBoxOn(opt_potion_armor) and target.Classification(worldboss) Item(mountains_potion usable=1)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "mountains_potion")
		count = count + 1
	end
	if annotation.use_potion_agility then
		local code = [[
			AddFunction UsePotionAgility
			{
				if CheckBoxOn(opt_potion_agility) and target.Classification(worldboss) Item(virmens_bite_potion usable=1)
			}
		]]
		local node = OvaleAST:ParseCode("add_function", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "virmens_bite_potion")
		count = count + 1
	end
	return count
end

local function InsertSupportingControls(child, annotation)
	local count = 0
	local nodeList = annotation.astAnnotation.nodeList
	if annotation.trap_launcher == "HUNTER" then
		local code = [[
			AddCheckBox(opt_trap_launcher SpellName(trap_launcher) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "trap_launcher")
		count = count + 1
	end
	if annotation.time_warp == "MAGE" then
		local code = [[
			AddCheckBox(opt_time_warp SpellName(time_warp) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "time_warp")
		count = count + 1
	end
	if annotation.chi_burst == "MONK" then
		local code = [[
			AddCheckBox(opt_chi_burst SpellName(chi_burst) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "chi_burst")
		count = count + 1
	end
	if annotation.bloodlust == "SHAMAN" then
		local code = [[
			AddCheckBox(opt_bloodlust SpellName(bloodlust) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "bloodlust")
		count = count + 1
	end
	if annotation.class == "PALADIN" then
		local code = [[
			AddCheckBox(opt_righteous_fury_check SpellName(righteous_fury) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "righteous_fury")
		count = count + 1
	end
	if annotation.use_potion_strength then
		local code = [[
			AddCheckBox(opt_potion_strength ItemName(mogu_power_potion) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "mogu_power_potion")
		count = count + 1
	end
	if annotation.use_potion_intellect then
		local code = [[
			AddCheckBox(opt_potion_intellect ItemName(jade_serpent_potion) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "jade_serpent_potion")
		count = count + 1
	end
	if annotation.use_potion_armor then
		local code = [[
			AddCheckBox(opt_potion_armor ItemName(mountains_potion) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "mountains_potion")
		count = count + 1
	end
	if annotation.use_potion_agility then
		local code = [[
			AddCheckBox(opt_potion_agility ItemName(virmens_bite_potion) default)
		]]
		local node = OvaleAST:ParseCode("checkbox", code, nodeList, annotation.astAnnotation)
		tinsert(child, 1, node)
		AddSymbol(annotation, "virmens_bite_potion")
		count = count + 1
	end
	return count
end
--</private-static-methods>

--<public-static-methods>
function OvaleSimulationCraft:OnInitialize()
	-- Resolve module dependencies.
	OvaleAST = Ovale.OvaleAST
	OvaleData = Ovale.OvaleData
	OvaleLexer = Ovale.OvaleLexer
	OvalePower = Ovale.OvalePower

	InitializeDisambiguation()
	self:CreateOptions()
end

function OvaleSimulationCraft:Debug()
	self_pool:Debug()
	self_childrenPool:Debug()
	self_outputPool:Debug()
end

function OvaleSimulationCraft:ToString(tbl)
	local output = print_r(tbl)
	return tconcat(output, "\n")
end

function OvaleSimulationCraft:Release(profile)
	if profile.annotation then
		local annotation = profile.annotation
		if annotation.astAnnotation then
			OvaleAST:ReleaseAnnotation(annotation.astAnnotation)
		end
		if annotation.nodeList then
			for _, node in ipairs(annotation.nodeList) do
				self_pool:Release(node)
			end
		end
		for key, value in pairs(annotation) do
			if type(value) == "table" then
				wipe(value)
			end
			annotation[key] = nil
		end
		profile.annotation = nil
	end
	profile.actionList = nil
end

function OvaleSimulationCraft:ParseProfile(simc)
	local profile = {}
	for line in gmatch(simc, "[^\r\n]+") do
		-- Trim leading and trailing whitespace.
		line = strmatch(line, "^%s*(.-)%s*$")
		if not (strmatch(line, "^#.*") or strmatch(line, "^$")) then
			-- Line is not a comment or an empty string.
			local key, operator, value = strmatch(line, "([^%+=]+)(%+?=)(.*)")
			if operator == "=" then
				profile[key] = value
			elseif operator == "+=" then
				if type(profile[key]) ~= "table" then
					local oldValue = profile[key]
					profile[key] = {}
					tinsert(profile[key], oldValue)
				end
				tinsert(profile[key], value)
			end
		end
	end
	-- Concatenate variables defined over multiple lines using +=
	for k, v in pairs(profile) do
		if type(v) == "table" then
			profile[k] = tconcat(v)
		end
	end
	-- Parse the action lists.
	local ok = true
	local annotation = {}
	local nodeList = {}
	local actionList = {}
	for k, v in pairs(profile) do
		if ok and strmatch(k, "^actions") then
			local name = strmatch(k, "^actions%.([%w_]+)") or "default"
			local node
			ok, node = ParseActionList(name, v, nodeList, annotation)
			if ok then
				actionList[#actionList + 1] = node
			else
				break
			end
		end
	end
	-- Set the name, class, specialization, and role from the profile.
	for class in pairs(RAID_CLASS_COLORS) do
		local lowerClass = strlower(class)
		if profile[lowerClass] then
			annotation.class = class
			annotation.name = profile[lowerClass]
		end
	end
	annotation.specialization = profile.spec
	annotation.level = profile.level
	ok = ok and (annotation.class and annotation.specialization and annotation.level)
	annotation.pet = profile.default_pet
	annotation.role = profile.role

	-- Set the attack range of the class and role.
	if profile.role == "tank" then
		annotation.melee = annotation.class
	elseif profile.role == "spell" then
		annotation.ranged = annotation.class
	elseif profile.role == "attack" or profile.role == "dps" then
		if profile.position == "ranged_back" then
			annotation.ranged = annotation.class
		else
			annotation.melee = annotation.class
		end
	end

	profile.actionList = actionList
	profile.annotation = annotation
	annotation.nodeList = nodeList

	if not ok then
		self:Release(profile)
		profile = nil
	end
	return profile
end

function OvaleSimulationCraft:Unparse(profile)
	local output = self_outputPool:Get()
	if profile.actionList then
		for _, node in ipairs(profile.actionList) do
			output[#output + 1] = Unparse(node)
		end
	end
	local s = tconcat(output, "\n")
	self_outputPool:Release(output)
	return s
end

function OvaleSimulationCraft:Emit(profile)
	local nodeList = {}
	local ast = OvaleAST:NewNode(nodeList, true)
	ast.type = "script"

	local annotation = profile.annotation
	if profile.actionList then
		local child = ast.child
		annotation.astAnnotation = annotation.astAnnotation or {}
		annotation.astAnnotation.nodeList = nodeList
		for _, node in ipairs(profile.actionList) do
			local declarationNode = EmitActionList(node, nodeList, annotation)
			if declarationNode then
				child[#child + 1] = declarationNode
			end
		end
		-- Fixups.
		do
			-- Some profiles don't include any interrupt actions.
			local class = annotation.class
			annotation.mind_freeze = class			-- deathknight
			annotation.counter_shot = class			-- hunter
			annotation.spear_hand_strike = class	-- monk
			annotation.silence = class				-- priest
			annotation.pummel = class				-- warrior
		end
		annotation.supportingFunctionCount = InsertSupportingFunctions(child, annotation)
		annotation.supportingControlCount = InsertSupportingControls(child, annotation)
	end

	local output = self_outputPool:Get()
	-- Prepend a comment block header for the script.
	do
		output[#output + 1] = "# Based on SimulationCraft profile " .. annotation.name .. "."
		output[#output + 1] = "#	class=" .. strlower(annotation.class)
		output[#output + 1] = "#	spec=" .. annotation.specialization
		if profile.talents then
			output[#output + 1] = "#	talents=" .. profile.talents
		end
		if profile.glyphs then
			output[#output + 1] = "#	glyphs=" .. profile.glyphs
		end
		if profile.default_pet then
			output[#output + 1] = "#	pet=" .. profile.default_pet
		end
	end
	-- Includes.
	do
		output[#output + 1] = ""
		output[#output + 1] = "Include(ovale_common)"
		output[#output + 1] = format("Include(ovale_%s_spells)", strlower(annotation.class))
		-- Insert an extra blank line to separate section for controls from the includes.
		if annotation.supportingControlCount > 0 then
			output[#output + 1] = ""
		end
	end
	-- Output the script itself.
	output[#output + 1] = OvaleAST:Unparse(ast)
	-- Output a simplistic two-icon layout for the rotation.
	do
		-- Single-target rotation.
		output[#output + 1] = ""
		output[#output + 1] = format("AddIcon specialization=%s help=main enemies=1", annotation.specialization)
		output[#output + 1] = "{"
		if profile["actions.precombat"] then
			output[#output + 1] = format("	if not InCombat() %s()", OvaleFunctionName("precombat", annotation))
		end
		output[#output + 1] = format("	%s()", OvaleFunctionName("default", annotation))
		output[#output + 1] = "}"
		-- AoE rotation.
		output[#output + 1] = ""
		output[#output + 1] = format("AddIcon specialization=%s help=aoe", annotation.specialization)
		output[#output + 1] = "{"
		if profile["actions.precombat"] then
			output[#output + 1] = format("	if not InCombat() %s()", OvaleFunctionName("precombat", annotation))
		end
		output[#output + 1] = format("	%s()", OvaleFunctionName("default", annotation))
		output[#output + 1] = "}"
	end
	-- Append the required symbols for the script.
	if profile.annotation.symbolTable then
		output[#output + 1] = ""
		output[#output + 1] = "### Required symbols"
		tsort(profile.annotation.symbolTable)
		for _, symbol in ipairs(profile.annotation.symbolTable) do
			output[#output + 1] = "# " .. symbol
		end
	end
	local s = tconcat(output, "\n")
	self_outputPool:Release(output)
	return s
end

function OvaleSimulationCraft:CreateOptions()
	local options = {
		name = OVALE .. " SimulationCraft",
		type = "group",
		args = {
			input = {
				name = L["Input"],
				type = "group",
				args = {
					input = {
						name = L["SimulationCraft Profile"],
						desc = L["The contents of a SimulationCraft profile (*.simc)."],
						type = "input",
						multiline = 25,
						width = "full",
						get = function(info) return self_lastSimC end,
						set = function(info, value)
							self_lastSimC = value
							local profile = self:ParseProfile(self_lastSimC)
							local code = ""
							if profile then
								code = self:Emit(profile) .. "\n"
							end
							-- Substitute spaces for tabs.
							self_lastScript = gsub(code, "\t", "    ")
						end,
					},
				},
			},
			output = {
				name = L["Output"],
				type = "group",
				args = {
					output = {
						name = L["Script"],
						desc = L["The script translated from the SimulationCraft profile."],
						type = "input",
						multiline = 25,
						width = "full",
						get = function() return self_lastScript end,
					},
				},
			},
		},
	}

	local appName = self:GetName()
	AceConfig:RegisterOptionsTable(appName, options)
	AceConfigDialog:AddToBlizOptions(appName, "SimulationCraft", OVALE)
end
--</public-static-methods>