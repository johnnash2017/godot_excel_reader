# Excel 文件读取器主类 | Main Excel Reader Class
class_name ExcelReader extends RefCounted

# Excel 文件操作类 | Excel File Handler Class
class ExcelFile:
	extends RefCounted  # 引用计数基类 | Reference counted base class
	
	var _zip_reader: ZIPReader        # ZIP 读取器实例 | ZIP reader instance
	var _workbook: ExcelWorkbook = null  # 工作簿缓存 | Workbook cache
	var _path:String
	
	# 构造函数 - 打开Excel文件（本质是ZIP包） | Constructor - Open Excel file (which is a ZIP package)
	func _init(path: String):
		_path=path
		_zip_reader = ZIPReader.new()
		if _zip_reader.open(_path) != OK:
			push_error("Excel文件打开失败: " + _path)  # 错误处理 | Error handling
		_zip_reader.close()
		
	# 获取工作簿（延迟初始化）| Get workbook (lazy initialization)
	func get_workbook() -> ExcelWorkbook:
		_zip_reader.open(_path)
		if not _workbook:
			_workbook = ExcelWorkbook.new(_zip_reader)
		_zip_reader.close()
		return _workbook
	
	# 静态方法打开Excel文件 | Static method to open Excel file
	static func open(path: String) -> ExcelFile:
		return ExcelFile.new(path) if FileAccess.file_exists(path) else null


# 工作簿解析类 | Workbook Parser Class
class ExcelWorkbook:
	extends RefCounted
	
	var _zip: ZIPReader                     # ZIP 读取器引用 | ZIP reader reference
	var _sheets: Array[ExcelSheet] = []     # 工作表列表 | List of worksheets
	var _shared_strings: PackedStringArray = []  # 共享字符串池 | Shared strings pool
	
	# 初始化并加载数据 | Initialize and load data
	func _init(zip: ZIPReader):
		_zip = zip
		_load_shared_strings()    # 加载共享字符串 | Load shared strings
		_discover_sheets()        # 发现所有工作表 | Discover all worksheets
	
	# 获取所有工作表名称 | Get all sheet names
	func get_sheet_names() -> PackedStringArray:
		var names: PackedStringArray = []
		for sheet in _sheets:
			names.append(sheet.name)
		return names
	
	# 通过名称获取工作表数据 | Get sheet data by name
	func get_sheet_by_name(sheet_name: String) -> Dictionary:
		var target_name = sheet_name.replace(" ", "").to_lower()  # 标准化名称比较 | Normalized name comparison
		for sheet in _sheets:
			if sheet.normalized_name == target_name:
				return {
					"name": sheet.name,
					"data": _convert_to_continuous_grid(sheet.rows)  # 转换为连续网格 | Convert to continuous grid
				}
		return {}
	
	# --------- 私有方法 | Private Methods ---------
	
	# 加载共享字符串 | Load shared strings
	func _load_shared_strings():
		if not _zip.file_exists("xl/sharedStrings.xml"):
			return
		
		var data = _zip.read_file("xl/sharedStrings.xml")
		var parser = XMLParser.new()
		parser.open_buffer(data)
		
		var current_string = ""
		var in_text = false  # 文本标记状态 | Text flag status
		
		# XML 解析循环 | XML parsing loop
		while parser.read() == OK:
			match parser.get_node_type():
				XMLParser.NODE_ELEMENT:
					if parser.get_node_name().to_lower() == "t":
						in_text = true  # 进入文本节点 | Enter text node
				XMLParser.NODE_TEXT:
					if in_text:
						current_string += parser.get_node_data().strip_edges()  # 收集文本内容 | Collect text content
				XMLParser.NODE_ELEMENT_END:
					if parser.get_node_name().to_lower() == "t":
						in_text = false  # 退出文本节点 | Exit text node
					elif parser.get_node_name().to_lower() == "si":
						_shared_strings.append(current_string)  # 保存完成字符串 | Save completed string
						current_string = ""

	# 发现工作表 | Discover worksheets
	func _discover_sheets():
		var sheet_map = _parse_workbook_relations()  # 解析关系映射 | Parse relationship map
		_parse_workbook_sheets(sheet_map)             # 解析具体工作表 | Parse actual worksheets

	# 解析工作簿关系 | Parse workbook relationships
	func _parse_workbook_relations() -> Dictionary:
		var relations = {}
		var rels_data = _zip.read_file("xl/_rels/workbook.xml.rels")
		if rels_data.is_empty():
			return relations
		
		var parser = XMLParser.new()
		parser.open_buffer(rels_data)
		
		# 解析XML关系 | Parse XML relationships
		while parser.read() == OK:
			if parser.get_node_type() == XMLParser.NODE_ELEMENT:
				var node_name = parser.get_node_name().to_lower()
				if node_name == "relationship":
					var rel_type = _get_attribute(parser, "type").to_lower()
					if "worksheet" in rel_type:
						var rid = _get_attribute(parser, "id")
						var target = "xl/" + _get_attribute(parser, "target").replace("\\", "/").lstrip("xl/")
						relations[rid] = target  # 记录关系映射 | Record relationship mapping
		return relations

	# 解析工作簿中的工作表 | Parse worksheets in workbook
	func _parse_workbook_sheets(sheet_map: Dictionary):
		var wb_data = _zip.read_file("xl/workbook.xml")
		if wb_data.is_empty():
			return
		
		var parser = XMLParser.new()
		parser.open_buffer(wb_data)
		
		# 解析工作表条目 | Parse sheet entries
		while parser.read() == OK:
			if parser.get_node_type() == XMLParser.NODE_ELEMENT:
				var node_name = parser.get_node_name().to_lower()
				if node_name == "sheet":
					var sheet_name = _get_attribute(parser, "name")
					var rid = _get_attribute(parser, "r:id", "id")
					var sheet_path = sheet_map.get(rid, "")
					if sheet_path and _zip.file_exists(sheet_path):
						_sheets.append(_parse_sheet(sheet_path, sheet_name))  # 添加解析好的工作表 | Add parsed sheet

	# 解析单个工作表 | Parse individual worksheet
	func _parse_sheet(path: String, name: String) -> ExcelSheet:
		var sheet_data = _zip.read_file(path)
		if sheet_data.is_empty():
			return ExcelSheet.new(name, [])
		
		var parser = XMLParser.new()
		parser.open_buffer(sheet_data)
		
		# 解析状态变量 | Parsing state variables
		var rows = []
		var current_row = {}
		var current_col = 0
		var max_col = 0
		var in_row = false
		var _in_cell = false
		var in_value = false
		var current_cell_type = ""
		
		# 主解析循环 | Main parsing loop
		while parser.read() == OK:
			match parser.get_node_type():
				XMLParser.NODE_ELEMENT:
					var node_name = parser.get_node_name().to_lower()
					match node_name:
						"row":
							in_row = true
							current_row = {}
							max_col = 0
						"c":
							_in_cell = true
							current_cell_type = _get_attribute(parser, "t", "")
							# 解析列字母（例如"A" -> 1）| Parse column letters (e.g. "A" -> 1)
							var r = _get_attribute(parser, "r", "")
							var col_str = ""
							for c in r:
								if c.is_valid_int(): break
								col_str += c
							current_col = _column_to_index(col_str)
							if current_col > max_col:
								max_col = current_col
						"v":
							in_value = true
				
				XMLParser.NODE_TEXT:
					if in_value:
						var value = parser.get_node_data().strip_edges()
						var parsed_value = _parse_cell_value(value, current_cell_type)  # 解析单元格值 | Parse cell value
						current_row[current_col] = parsed_value
				
				XMLParser.NODE_ELEMENT_END:
					var node_name = parser.get_node_name().to_lower()
					match node_name:
						"row":
							if in_row:
								# 填充空单元格 | Fill empty cells
								var filled_row = {}
								for col in range(1, max_col + 1):
									filled_row[col] = current_row.get(col, "")
								rows.append(filled_row)
								in_row = false
						"c":
							_in_cell = false
							current_cell_type = ""
						"v":
							in_value = false
		
		return ExcelSheet.new(name, rows)

	# 解析单元格值 | Parse cell value
	func _parse_cell_value(value: String, type: String):
		if type == "s":  # 共享字符串类型 | Shared string type
			if value.is_valid_int():
				var index = value.to_int()
				return _shared_strings[index] if index < _shared_strings.size() else ""
			return value
		else:
			# 合并数值解析逻辑
			if value.is_valid_float():
				var num = value.to_float()
				# 检查是否为整数 | Check if it's an integer
				if num == int(num):
					return int(num)  # 返回整数 | Return integer
				else:
					return num      # 返回浮点数 | Return float
			else:
				return value        # 无法解析时返回原值 | Fallback

	# XML属性获取工具方法 | XML attribute getter utility
	func _get_attribute(parser: XMLParser, name: String, fallback: String = "") -> String:
		for i in range(parser.get_attribute_count()):
			if parser.get_attribute_name(i).to_lower() == name.to_lower():
				return parser.get_attribute_value(i)
		return fallback

	# Excel列字母转数字 | Convert Excel column letters to numbers
	func _column_to_index(col: String) -> int:
		var index = 0
		for c in col.to_upper():
			index = index * 26 + (c.unicode_at(0) - 64)  # A=65 -> 1
		return index

	# 转换为连续行列号 | Convert to continuous grid numbering
	func _convert_to_continuous_grid(rows: Array) -> Dictionary:
		var grid = {}
		for row_idx in range(rows.size()):
			var row_num = row_idx + 1  # 行号从1开始 | Row numbers start from 1
			grid[row_num] = rows[row_idx]
		return grid


# 工作表数据容器类 | Worksheet Data Container
class ExcelSheet:
	extends RefCounted
	
	var name: String                   # 原始工作表名称 | Original sheet name
	var normalized_name: String        # 标准化名称（小写无空格）| Normalized name (lowercase no spaces)
	var rows: Array                    # 行数据存储 | Row data storage
	
	func _init(sheet_name: String, data: Array):
		name = sheet_name
		normalized_name = name.replace(" ", "").to_lower()
		rows = data
