extends Node
const EXCEL_PATH = "res://table.xlsx"

func _ready():
	var excel = ExcelReader.ExcelFile.open(EXCEL_PATH)
	var workbook = excel.get_workbook()
	print("Sheet: ", workbook.get_sheet_names())
	
	var sheet_data = workbook.get_sheet_by_name("Sheet1")
	print(JSON.stringify(sheet_data["name"], "\t"))
	print(JSON.stringify(sheet_data["data"], "\t"))
	var sheet_data2 = workbook.get_sheet_by_name("Sheet2")
	
	print(JSON.stringify(sheet_data2["name"], "\t"))
	print(JSON.stringify(sheet_data2["data"], "\t"))
