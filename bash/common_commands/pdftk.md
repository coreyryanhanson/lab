# pdftk

Split off pdf pages:  
`pdftk <inputpdf> cat <pagenumbers> output <outputpdf>`  
***Note:** With cat argument page numbers can be a sequence of pages separated by spaces of a range with a - character.*

Combine pdf pages:  
`pdftk <input1pdf> <input2pdf> cat output <outputpdf>`

Overlay pdf pages on top of one another.  
`pdftk <foregroundpdf> background <backgroundpdf> output <outputpdf>`
