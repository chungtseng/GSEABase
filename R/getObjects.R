## file: source
## node: XPATH node identifier (syntax: http://www.w3.org/TR/xpath#path-abbrev)
## handler: function of 1 argument converting each node to GeneSet
.fromXML <- function(file, node, handler, ...) {
    res <- xmlTreeParse(file, useInternalNodes=TRUE, ...)
    geneSets <- getNodeSet(res, node, fun=handler)
    free(res)
    geneSets
}

.toXML <- function(geneSet, handler, con, ...) {
    saveXML(handler(geneSet), file=con, ...)
}

## Broad gene set, see http://www.broad.mit.edu/gsea/
.BROAD_SEPARATOR = ","                  # not specficied in DTD

.BroadXMLNodeToGeneSet_factory <- function(file, membersId="MEMBERS_SYMBOLIZED") {
    ## state
    .mkSplit <- function(x) {
        if (is.null(x)) character(0)
        else unlist(strsplit(x, .BROAD_SEPARATOR))
    }
    url <- NULL
    if (length(file)==1) {
        isUri <- grep("^(http|ftp|file)://", file)
        if (length(isUri)==1 && isUri==1)
            url <- file
        else if (file.exists(file)) {
            full <- path.expand(file)
            if (length(grep("^/", full))==1)
                url <- paste("file:/", full, sep="")
            else if (.Platform$OS.type=="windows")
                url <- paste("file:///", full, sep="")
            else
                url = full
        }
    }
    ## handler: XMLNode -> GeneSet
    symbolId <- SymbolIdentifier()
    function(node) {
        attrs <- as.list(xmlAttrs(node))
        args <- list(symbolId,
                     setName=attrs[["STANDARD_NAME"]],
                     setIdentifier=attrs[["SYSTEMATIC_NAME"]],
                     geneIds=unique(.mkSplit(attrs[[membersId]])),
                     organism=attrs[["ORGANISM"]],
                     urls= c(getBroadSet=url,
                       .mkSplit(attrs[["EXTERNAL_DETAILS_URL"]])),
                     collectionType={
                         categories <-
                             .mkSplit(attrs[["CATEGORY_CODE"]])
                         subcategories <-
                             .mkSplit(attrs[["SUB_CATEGORY_CODE"]])
                         category <- subcategory <- as.character(NA)
                         if (length(categories)>=1)
                             category <- tolower(categories[[1]])
                         if (length(subcategories) >= 1)
                             subcategory <- subcategories[[1]]
                         else if (length(categories)>=2)
                             subcategory <- categories[[2]]
                         if (length(categories) > 2 ||
                             (length(categories) > 1 &&
                              length(subcategories) != 0)) {
                             fmt <- "Broad 'CATEGORY_CODE' too long: '%s'"
                             txt <- paste(categories, collapse="' '")
                             warning(sprintf(fmt, txt))
                         }
                         BroadCollection(category=mkScalar(category),
                                         subCategory=mkScalar(subcategory))
                     },
                     contributor=attrs[["CONTRIBUTOR"]],
                     pubMedIds=attrs[["PMID"]],
                     shortDescription=attrs[["DESCRIPTION_BRIEF"]],
                     longDescription=attrs[["DESCRIPTION_FULL"]],
                     TAGS=NULL, MESH=NULL, CHIP=NULL, MEMBERS=NULL)
        args <- args[!sapply(args, is.null)]
        do.call(GeneSet, args)
    }
}

.GeneSetToBroadXMLNode <- function(geneSet) {
    ## return text representation
    xmlNode("GENESET",
            attrs=c(
              STANDARD_NAME=setName(geneSet),
              SYSTEMATIC_NAME=setIdentifier(geneSet),
              ORGANISM=organism(geneSet),
              EXTERNAL_DETAILS_URL=paste(urls(geneSet),
                collapse=.BROAD_SEPARATOR),
              CATEGORY_CODE={
                  ct <- collectionType(geneSet)
                  category <- toupper(bcCategory(ct))
                  subcategory <- bcSubCategory(ct)
                  paste(if (is.na(category)) NULL else category,
                        if (is.na(subcategory)) NULL else subcategory,
                        collapse=.BROAD_SEPARATOR, sep="")
              },
              CONTRIBUTOR=contributor(geneSet),
              PMID=pubMedIds(geneSet),
              DESCRIPTION_FULL=longDescription(geneSet),
              DESCRIPTION_BRIEF=description(geneSet),
              MEMBERS_SYMBOLIZED=paste(geneIds(geneSet), collapse=",")
##               TAGS="",
##               MESH="",
##               CHIP="",
##               MEMBERS=""
              ))
}

asBroadUri <- function(name,
                       base="http://www.broad.mit.edu/gsea/msigdb/cards") {
    paste(base, "/", name, ".xml", sep="")
}

getBroadSets <-
    function(uri, ..., membersId=c("MEMBERS_SYMBOLIZED", "MEMBERS_EZID"))
{
    membersId <- match.arg(membersId)
    factories <- sapply(uri, .BroadXMLNodeToGeneSet_factory,
                        membersId=membersId)
    tryCatch({
        geneSets <- unlist(mapply(.fromXML, uri, "//GENESET", factories,
                                  SIMPLIFY=FALSE, USE.NAMES=FALSE))
    }, error=function(err) {
        stop("'getBroadSets' failed to create gene sets:\n  ",
             conditionMessage(err),
             call.=FALSE)
    })
    GeneSetCollection(geneSets)
}

toBroadXML <- function(geneSet, con = NULL, ...) {
    if (!is(collectionType(geneSet), "BroadCollection"))
        .stopf("toBroadXML requires 'BroadCollection', got '%s'",
               paste(class(collectionType(geneSet)), collapse=" "))
    tryCatch({
        .toXML(geneSet, .GeneSetToBroadXMLNode, con=con, ...)
    }, error=function(err) {
        .stopf("toBroadXML failed to create XML: %s\n",
               conditionMessage(err))
    })
}

## gmt

.toGmtRow <- function(set)
    paste(setName(set), description(set),
          paste(geneIds(set), collapse="\t"),
          sep="\t")

getGmt <- function(con,
                   geneIdType=NullIdentifier(),
                   collectionType=NullCollection(), sep="\t", ...) {
    lines <- strsplit(readLines(con, ...), sep)
    if (any(sapply(lines, length)<2)) {
        txt <- paste(
            "all records in the GMT file must have >= 2 fields",
            "\n  first invalid line:  %s\n", collpase="")
        .stopf(txt, lines[sapply(lines, length)<2][[1]])
    }
    dups <- new.env(parent=emptyenv())
    lines <- lapply(lines, function(elt, dups) {
        if (any(d <- duplicated(elt[-(1:2)]))) {
            dups[[elt[[1]]]] <- unique(elt[-(1:2)][d])
            elt <- c(elt[1:2], unique(elt[-(1:2)]))
        }
        elt
    }, dups)
    if (length(dups))
        .warningf("%d record(s) contain duplicate ids: %s",
                  length(dups),
                  paste(selectSome(sort(ls(dups))), collapse=", "))
    template <- GeneSet(geneIdType=geneIdType, collectionType=collectionType)
    GeneSetCollection(lapply(lines, function(line) {
        initialize(template, geneIds=unlist(line[-(1:2)]),
                   setName=line[[1]], shortDescription=line[[2]],
                   setIdentifier=.uniqueIdentifier())
    }))
}
