Attribute VB_Name = "modSerialise"
' Copyright (c) 2021 - Philip Swannell
' License MIT (https://opensource.org/licenses/MIT)
' Document: https://github.com/PGS62/JuliaExcel.jl#readme

Option Explicit
Option Private Module
Option Base 1

'Data format used by Serialise and Unserialise
'=============================================
'Format designed to be as fast as possible to unserialise.
'- Singleton types are prefixed with a type indicator character.
'- Dates are converted to their Excel representation - faster to unserialise in VBA.
'- Arrays are written with type indicator *, then three sections separated by semi-colons:
'  First section gives the number of dimensions and the dimensions themselves, comma
'  delimited e.g. a 3 x 4 array would have a dimensions section "2,3,4".
'  Second section gives the lengths of the encodings of each element, comma delimited with a
'  terminating comma.
'  Third section gives the encodings, concatenated with no delimiter.
'- Note that arrays are written in column-major order.
'- Nested arrays (arrays containing arrays) are supported by the format, and by VBA but
'  cannot be returned to a worksheet.

'Type indicator characters are as follows:
' # Double
' � (pound sterling) String
' T Boolean True
' F Boolean False
' D Date
' E Empty
' N Null
' % Integer
' & Long
' S Single
' C Currency
' ! Error
' @ Decimal
' * Array

'
'Examples:
'?Serialise(CDbl(1))
'#1
'?Serialise(CLng(1))
'&1
'?Serialise("Hello")
'�Hello
'?Serialise(True)
'T
'?Serialise(False)
'F
'?Serialise(Array(1,2,3.0,True,False,"Hello","World"))
'*1,7;2,2,2,1,1,6,6,;%1%2#3TF�Hello�World

' -----------------------------------------------------------------------------------------------------------------------
' Procedure  : UnserialiseFromFile
' Purpose    : Read the file saved by the Julia code and unserialise its contents.
' -----------------------------------------------------------------------------------------------------------------------
Function UnserialiseFromFile(FileName As String, AllowNested As Boolean, StringLengthLimit As Long, JuliaVectorToXLColumn As Boolean)
          Dim Contents As String
          Dim ErrMsg As String
          Dim FSO As New Scripting.FileSystemObject
          Dim ts As Scripting.TextStream

1         On Error GoTo ErrHandler
2         Set ts = FSO.OpenTextFile(FileName, ForReading, , TristateTrue)
3         Contents = ts.ReadAll
4         ts.Close
5         Set ts = Nothing

6         UnserialiseFromFile = Unserialise(Contents, AllowNested, 0, StringLengthLimit, JuliaVectorToXLColumn)
7         Exit Function
ErrHandler:
8         ErrMsg = "#UnserialiseFromFile (line " & CStr(Erl) + "): " & Err.Description & "!"
9         If Not ts Is Nothing Then ts.Close
10        Throw ErrMsg
End Function

' -----------------------------------------------------------------------------------------------------------------------
' Procedure  : GetStringLengthLimit
' Purpose    : Different versions of Excel have different limits for the longest string that can be an element of an
'              array passed from a VBA UDF back to Excel. I know the limit is 255 for Excel 2010 and earlier, and is
'              32,767 for Excel 365 (as of Sep 2021). But don't yet know the limit for Excel 2013, 2016 and 2019.
' Tried to get info from StackOverflow, without much joy:
' https://stackoverflow.com/questions/69303804/excel-versions-and-limits-on-the-length-of-string-elements-in-arrays-returned-by
' Note that this function returns 1 more than the maximum allowed string length
' -----------------------------------------------------------------------------------------------------------------------
Function GetStringLengthLimit() As Long
          Static Res As Long
1         If Res = 0 Then
2             Select Case Val(Application.Version)
                  Case Is <= 14 'Excel 2010
3                     Res = 256
4                 Case 15
5                     Res = 32768 'Don't yet know if this is correct for Excel 2013
6                 Case Else
7                     Res = 32768 'Excel 2016, 2019, 365. Hopefully these versions (which all _
                                   return 16 as Application.Version) have the same limit.
8             End Select
9         End If
10        GetStringLengthLimit = Res
End Function

' -----------------------------------------------------------------------------------------------------------------------
' Procedure  : Unserialise
' Purpose    : Unserialises the contents of the results file saved by JuliaExcel julia code.
' -----------------------------------------------------------------------------------------------------------------------
Function Unserialise(Chars As String, AllowNesting As Boolean, ByRef Depth As Long, StringLengthLimit As Long, JuliaVectorToXLColumn As Boolean)

1         On Error GoTo ErrHandler
2         Depth = Depth + 1
3         Select Case Asc(Left$(Chars, 1))
              Case 35    '# vbDouble
4                 Unserialise = CDbl(Mid$(Chars, 2))
5             Case 163    '� (pound sterling) vbString
6                 If StringLengthLimit > 0 Then
7                     If Len(Chars) > StringLengthLimit Then
8                         Throw "Data contains a string of length " & Format(Len(Chars) - 1, "###,###") & _
                              ", too long to display in Excel version " + Application.Version() + " (the limit is " _
                              & Format(StringLengthLimit - 1, "###,###") + ")"
9                     End If
10                End If
11                Unserialise = Mid$(Chars, 2)
12            Case 84     'T Boolean True
13                Unserialise = True
14            Case 70     'F Boolean False
15                Unserialise = False
16            Case 68     'D vbDate
17                Unserialise = CDate(Mid$(Chars, 2))
18            Case 69     'E vbEmpty
19                Unserialise = Empty
20            Case 78     'N vbNull
21                Unserialise = Null
22            Case 37     '% vbInteger
23                Unserialise = CInt(Mid$(Chars, 2))
24            Case 38     '& Int64 converts to LongLong on 64bit, Double on 32bit
25                Unserialise = parseInt64(Mid$(Chars, 2))
26            Case 83     'S vbSingle
27                Unserialise = CSng(Mid$(Chars, 2))
28            Case 67    'C vbCurrency
29                Unserialise = CCur(Mid$(Chars, 2))
30            Case 33     '! vbError
31                Unserialise = CVErr(Mid$(Chars, 2))
32            Case 64     '@ vbDecimal
33                Unserialise = CDec(Mid$(Chars, 2))
34            Case 42     '* vbArray
35                If Depth > 1 Then If Not AllowNesting Then Throw "Excel cannot display arrays containing arrays"
                  Dim Ret() As Variant
                  Dim p1 As Long 'Position of first semi-colon
                  Dim p2 As Long 'Position of second semi-colon
                  Dim m As Long '"pointer" to read from lengths section
                  Dim m2 As Long
                  Dim k As Long '"pointer" to read from contents section
                  Dim thislength As Long
                  Dim i As Long ' Index into Ret
                  Dim j As Long 'Index into Ret
              
36                p1 = InStr(Chars, ";")
37                p2 = InStr(p1 + 1, Chars, ";")
38                m = p1 + 1
39                k = p2 + 1
              
40                Select Case Mid$(Chars, 2, 1)
                      Case 1 '1 dimensional array
                          Dim N As Long 'Num elements in array
41                        N = Mid$(Chars, 4, p1 - 4)
42                        If N = 0 Then Throw "Cannot create array of size zero"
43                        If JuliaVectorToXLColumn Then
44                            ReDim Ret(1 To N, 1 To 1)
45                            For i = 1 To N
46                                m2 = InStr(m + 1, Chars, ",")
47                                thislength = Mid$(Chars, m, m2 - m)
48                                Ret(i, 1) = Unserialise(Mid$(Chars, k, thislength), AllowNesting, Depth, StringLengthLimit, JuliaVectorToXLColumn)
49                                k = k + thislength
50                                m = m2 + 1
51                            Next i
52                        Else
53                            ReDim Ret(1 To N)
54                            For i = 1 To N
55                                m2 = InStr(m + 1, Chars, ",")
56                                thislength = Mid$(Chars, m, m2 - m)
57                                Ret(i) = Unserialise(Mid$(Chars, k, thislength), AllowNesting, Depth, StringLengthLimit, JuliaVectorToXLColumn)
58                                k = k + thislength
59                                m = m2 + 1
60                            Next i
61                        End If

62                        Unserialise = Ret
63                    Case 2 '2 dimensional array
                          Dim commapos As Long
                          Dim NC As Long
                          Dim NR As Long
64                        commapos = InStr(4, Chars, ",")
65                        NR = Mid$(Chars, 4, commapos - 4)
66                        NC = Mid$(Chars, commapos + 1, p1 - commapos - 1)
67                        If NR = 0 Or NC = 0 Then Throw "Cannot create array of size zero"
68                        ReDim Ret(1 To NR, 1 To NC)
69                        For j = 1 To NC
70                            For i = 1 To NR
71                                m2 = InStr(m + 1, Chars, ",")
72                                thislength = Mid$(Chars, m, m2 - m)
73                                Ret(i, j) = Unserialise(Mid$(Chars, k, thislength), AllowNesting, Depth, StringLengthLimit, JuliaVectorToXLColumn)
74                                k = k + thislength
75                                m = m2 + 1
76                            Next i
77                        Next j
78                        Unserialise = Ret
79                    Case Else
80                        Throw "Cannot unserialise arrays with more than 2 dimensions"
81                End Select
82            Case Else
83                Throw "Character '" & Left$(Chars, 1) & "' is not recognised as a type identifier"
84        End Select

85        Exit Function
ErrHandler:
86        Throw "#Unserialise (line " & CStr(Erl) + "): " & Err.Description & "!"
End Function

'Values of type Int64 in Julia must be handled differently on Excel 32-bit and Excel 64bit
#If Win64 Then
    Function parseInt64(x As String)
        parseInt64 = CLngLng(x)
    End Function
#Else
    Function parseInt64(x As String)
        parseInt64 = CDbl(x)
    End Function
#End If

' -----------------------------------------------------------------------------------------------------------------------
' Procedure  : SerialiseToFile
' Purpose    : Serialise Data and write to file, the inverse of UnserialiseFromFile. Currently this procedure is not used
'              but might be useful for writing tests of UnserialiseFromFile.
' -----------------------------------------------------------------------------------------------------------------------
Function SerialiseToFile(Data, FileName As String)

          Dim ErrMsg As String
          Dim FSO As New Scripting.FileSystemObject
          Dim ts As Scripting.TextStream

1         On Error GoTo ErrHandler
2         If TypeName(Data) = "Range" Then Data = Data.Value2
3         Set ts = FSO.OpenTextFile(FileName, ForWriting, True, TristateTrue)
4         ts.Write Serialise(Data)
5         ts.Close
6         Set ts = Nothing
7         SerialiseToFile = FileName

8         Exit Function
ErrHandler:
9         ErrMsg = "#SerialiseToFile (line " & CStr(Erl) + ") error writing'" & FileName & "' " & Err.Description & "!"
10        If Not ts Is Nothing Then ts.Close
11        Throw ErrMsg
End Function

' -----------------------------------------------------------------------------------------------------------------------
' Procedure  : Serialise
' Date       : 04-Nov-2021
' Purpose    : Equivalent to the julia function in JuliaExcel.encode_for_xl and serialises to the same format, though this
'              VBA version is not currently used.
' -----------------------------------------------------------------------------------------------------------------------
Function Serialise(x As Variant) As String

          Dim contentsArray() As String
          Dim i As Long
          Dim j As Long
          Dim k As Long
          Dim lengthsArray() As String
          Dim NC As Long
          Dim NR As Long

1         On Error GoTo ErrHandler
2         Select Case VarType(x)
              Case vbEmpty
3                 Serialise = "E"
4             Case vbNull
5                 Serialise = "N"
6             Case vbInteger
7                 Serialise = "%" & CStr(x)
8             Case vbLong
9                 Serialise = "&" & CStr(x)
10            Case vbSingle
11                Serialise = "S" & CStr(x)
12            Case vbDouble
13                Serialise = "#" & CStr(x)
14            Case vbCurrency
15                Serialise = "C" & CStr(x)
16            Case vbDate
17                Serialise = "D" & CStr(CDbl(x))
18            Case vbString
19                Serialise = "�" & x
20            Case vbError
21                Serialise = "!" & CStr(CLng(x))
22            Case vbBoolean
23                Serialise = IIf(x, "T", "F")
24            Case vbDecimal
25                Serialise = "@" & CStr(x)
26            Case Is >= vbArray
27                Select Case NumDimensions(x)
                      Case 1
28                        ReDim lengthsArray(LBound(x) To UBound(x))
29                        ReDim contentsArray(LBound(x) To UBound(x))
30                        For i = LBound(x) To UBound(x)
31                            contentsArray(i) = Serialise(x(i))
32                            lengthsArray(i) = CStr(Len(contentsArray(i)))
33                        Next i
34                        Serialise = "*1," & CStr(UBound(x) - LBound(x) + 1) & ";" & VBA.Join(lengthsArray, ",") & ",;" & VBA.Join(contentsArray, "")
35                    Case 2
36                        NR = UBound(x, 1) - LBound(x, 1) + 1
37                        NC = UBound(x, 2) - LBound(x, 2) + 1
38                        k = 0
39                        ReDim lengthsArray(NR * NC)
40                        ReDim contentsArray(NR * NC)
41                        For j = LBound(x, 2) To UBound(x, 2)
42                            For i = LBound(x, 1) To UBound(x, 1)
43                                k = k + 1
44                                contentsArray(k) = Serialise(x(i, j))
45                                lengthsArray(k) = CStr(Len(contentsArray(k)))
46                            Next i
47                        Next j
48                        Serialise = "*2," & CStr(UBound(x, 1) - LBound(x, 1) + 1) & "," & CStr(UBound(x, 2) - LBound(x, 2) + 1) & ";" & VBA.Join(lengthsArray, ",") & ",;" & VBA.Join(contentsArray, "")
49                    Case Else
50                        Throw "Cannot serialise array with " + CStr(NumDimensions(x)) + " dimensions"
51                End Select
52            Case Else
53                Throw "Cannot serialise variable of type " & TypeName(x)
54        End Select

55        Exit Function
ErrHandler:
56        Throw "#Serialise (line " & CStr(Erl) + "): " & Err.Description & "!"
End Function
