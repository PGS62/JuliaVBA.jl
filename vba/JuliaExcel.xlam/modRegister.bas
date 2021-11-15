Attribute VB_Name = "modRegister"
Option Explicit
Option Private Module

' -----------------------------------------------------------------------------------------------------------------------
' Procedure  : RegisterExcelJuliaFunctionsWithFunctionWizard
' Purpose    : Register functions with the Excel function wizard, taking the information form the Intellisense sheet
'              that is also parsed by Excel.DNA Intellisense add-in.
' -----------------------------------------------------------------------------------------------------------------------
Sub RegisterExcelJuliaFunctionsWithFunctionWizard()

          Dim ArgDescs() As String
          Dim c As Range
          Dim Description As String
          Dim FunctionName As String
          Dim i As Long
          Dim NumArgs
          Dim OldIsAddinStatus As Boolean
          Dim OldSaveStatus As Boolean
          Dim rngArgsAndArgDescs As Range
          Dim rngFunctions As Range
          
1         On Error GoTo ErrHandler
2         OldSaveStatus = ThisWorkbook.Saved
3         OldIsAddinStatus = ThisWorkbook.IsAddin
          'Without setting .IsAddin to False, I see errors:
          '"Cannot edit a macro on a hidden workbook. Unhide the workbook using the Unhide command."
          'Not ideal, setting IsAddin to False causes screen flicker.
4         If OldIsAddinStatus Then
5             Application.ScreenUpdating = False
6             ThisWorkbook.IsAddin = False
7         End If

8         With shIntellisense
9             Set rngFunctions = .Range(.Cells(2, 1), .Cells(1, 1).End(xlDown))
10        End With

11        For Each c In rngFunctions.Cells
12            FunctionName = c.Value
13            Description = c.Offset(0, 1).Value
        
14            If IsEmpty(c.Offset(, 3).Value) Then
15                NumArgs = 0
16            Else
17                Set rngArgsAndArgDescs = Range(c.Offset(, 3), c.Offset(, 3).End(xlToRight))
18                NumArgs = rngArgsAndArgDescs.Columns.Count / 2
19                ReDim ArgDescs(1 To NumArgs)
20                For i = 1 To NumArgs
21                    ArgDescs(i) = rngArgsAndArgDescs.Cells(1, i * 2 - 1).Value
22                Next i
23            End If

24            If NumArgs = 0 Then
25                MacroOptions FunctionName, Description
26            Else
27                MacroOptions FunctionName, Description, ArgDescs
28            End If
29        Next c
30        If OldIsAddinStatus Then
31            ThisWorkbook.IsAddin = True
32            ThisWorkbook.Saved = OldSaveStatus
33        End If

34        Exit Sub
ErrHandler:
35        Debug.Print "#RegisterExcelJuliaFunctionsWithFunctionWizard (line " & CStr(Erl) + "): " & Err.Description & "!"
End Sub

Function MacroOptions(FunctionName As String, Description As String, Optional ArgDescs As Variant)
1         On Error GoTo ErrHandler
2         Application.MacroOptions FunctionName, Description, , , , , gPackageName, , , , ArgDescs
3         Exit Function
ErrHandler:
4         Debug.Print "Warning from " + gPackageName + ": Registration of function " & FunctionName & " failed with error: " + Err.Description
End Function

