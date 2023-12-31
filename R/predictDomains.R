#' Predict protein domain families from coding transcripts
#'
#' @param x
#' Can be a GRanges object containing 'CDS' features in GTF format
#'
#' Can be a GRangesList object containing CDS ranges for each transcript
#' @param fasta
#' BSgenome or Biostrings object containing genomic sequence
#' @param ...
#' Logical conditions to pass to dplyr::filter to subset transcripts for 
#' analysis. Variables are metadata information found in `x` and multiple 
#' conditions can be provided delimited by comma. 
#' Example: transcript_id == "transcript1"
#' @param plot
#' Argument whether to plot out protein domains (Default: FALSE).
#' Note: only first 20 proteins will be plotted
#' @param progress_bar
#' Argument whether to show progress bar (Default: FALSE). Useful to track
#' progress of predicting a long list of proteins.
#' @param ncores
#' Number of cores to utilise to perform prediction
#'
#' @return
#' Dataframe containing protein features for each cds entry
#'
#' @examples
#' ## ---------------------------------------------------------------------
#' ## EXAMPLE USING SAMPLE DATASET
#' ## ---------------------------------------------------------------------
#' # Load Mouse genome sequence
#' library(BSgenome.Mmusculus.UCSC.mm10)
#' 
#' # Load dataset
#' data(new_query_gtf)
#'
#' # predict domains of all CDSs in query GTF
#' predictDomains(new_query_gtf, Mmusculus, ncores=1)
#'
#' # predict domains of CDSs from Ptbp1 gene
#' predictDomains(new_query_gtf, Mmusculus, gene_name == "Ptbp1",ncores=1)
#'
#' # predict domains of CDSs from Ptbp1 gene and plot architecture out
#' predictDomains(new_query_gtf, Mmusculus, gene_name == "Ptbp1", plot = TRUE,ncores=1)
#' @author Fursham Hamid
#' @export
predictDomains <- function(x, fasta, ..., plot = FALSE, 
                           progress_bar = FALSE, ncores = 4) {

    # catch missing args
    mandargs <- c("x", "fasta")
    passed <- names(as.list(match.call())[-1])
    if (any(!mandargs %in% passed)) {
        rlang::abort(paste(
            "missing values for",
            paste(setdiff(mandargs, passed), collapse = ", ")
        ))
    }

    # get argnames and carry out checks
    argnames <- as.character(match.call())[-1]
    cds <- .extractCDSchecks(x, fasta, argnames, ...)

    # define global variables
    . <- id <- NULL

    # get sequence
    aaSeq <- .getSequence(cds, fasta)

    output_table <- .runDomainSearch(aaSeq, plot, progress_bar, ncores)

    return(output_table)
}


.extractCDSchecks <- function(cds, fasta, argnames, ...) {
    # define global variables
    exonorder <- NULL

    if (!has_consistentSeqlevels(cds, fasta, verbose = FALSE)) {
        rlang::abort(sprintf(
            "`%s` and `%s` has unmatched seqlevel styles. 
Try running: %s <- matchChromosomes(%s, %s)",
            argnames[1], argnames[2], argnames[1], argnames[1], argnames[2]
        ))
    }
    # catch wrong cds class
    if (is_gtf(cds)) {
        cds <- S4Vectors::split(cds[cds$type == "CDS"], ~transcript_id)
        if (length(cds) == 0) {
            rlang::abort(sprintf(
                "`%s` do not contain CDS information", argnames[1]
            ))
        }
    }

    if (!is(cds, "GRangesList")) {
        rlang::abort("cds class type is not GRanges GTF or GRangesList")
    }

    cds <- filtereach(cds, ...)
    if (length(cds) == 0) {
        rlang::abort("No CDS to display")
    }
    return(sorteach(cds, exonorder))
}


.getSequence <- function(cds, fasta) {
    x <- y <- instop <- NULL
    
    rlang::inform("Checking CDSs and translating protein sequences")
    cdsSeq <- GenomicFeatures::extractTranscriptSeqs(fasta, cds)
    aaSeq <- suppressWarnings(
        Biostrings::translate(cdsSeq, if.fuzzy.codon = "solve")) %>%
        as.data.frame() %>%
        tibble::rownames_to_column("id") %>%
        dplyr::rowwise() %>%
        dplyr::mutate(y = strsplit(x, split = "")) %>%
        dplyr::mutate(noATG = ifelse(y[[1]] != "M", TRUE, FALSE)) %>%
        dplyr::mutate(instop = ifelse("*" %in% y, TRUE, FALSE)) %>%
        dplyr::ungroup()

    # check for ATG and internal stop_codon, truncate proteins with internal 
    # stop codon
    ## and remove entries without proteins after truncation
    if (TRUE %in% aaSeq$noATG) {
        rlang::warn(sprintf("%s CDSs do not begin with ATG", sum(aaSeq$noATG)))
    }
    if (TRUE %in% aaSeq$instop) {
        aaSeq <- suppressWarnings(aaSeq %>%
            dplyr::rowwise() %>%
            dplyr::mutate(x = ifelse(instop == TRUE,
                paste(y[seq_len(which(y == "*") - 1)], collapse = ""),
                x
            )) %>%
            dplyr::mutate(y = strsplit(x, split = "")) %>%
            dplyr::ungroup())

        rlang::warn(sprintf(paste0("%s CDSs contain internal stop codon. ",
                                   "Truncating CDS sequence to retain ORF"), 
                            sum(aaSeq$instop)))
        if ("" %in% aaSeq$x) {
            rlang::warn(sprintf(paste0(
                "After truncation, %s cds have no ",
                "coding sequences. These CDSs were not analyzed"), 
                sum(aaSeq$x == "")))
            aaSeq <- aaSeq[aaSeq$x != "", ]
        }
    }
    rlang::inform(sprintf(
        "Predicting domain families for %s proteins", nrow(aaSeq)))
    return(aaSeq)
}



.getdomains <- function(url, curl.opts, seq, id, length, n) {
    type <- famdesc <- fameval <- begin <- NULL
    
    hmm <- ""
    while(!grepl("data name=\"results\"", hmm)){
        hmm <- RCurl::postForm(url,
                               hmmdb = "superfamily", seqdb = NULL,
                               seq = seq, style = "POST", .opts = curl.opts,
                               .contentEncodeFun = RCurl::curlPercentEncode,
                               .checkParams = TRUE
        )
        if (grepl("status=\"PEND\"", hmm)) {
            Sys.sleep(30)
        }
    }

    xml <- XML::xmlParse(hmm)
    domains <- XML::xpathSApply(xml, "///domains", XML::xpathSApply, "@*")
    family <- XML::xpathSApply(xml, "///family", XML::xpathSApply, "@*")
    family[2,] <- domains['alihmmdesc',]
    segment <- XML::xpathSApply(xml, "///segments", XML::xpathSApply, "@*")

    if (ncol(family) != ncol(segment)) {
        ndomains <- XML::xpathSApply(xml, "///domains", 
                                     XML::xpathSApply, "count(segments)")
        family2 <- suppressMessages(lapply(seq_along(ndomains), function(x) {
            return(family[, rep(x, each = ndomains[x])])
        }) %>% dplyr::bind_cols() %>% as.matrix())
        rownames(family2) <- rownames(family)
        data <- rbind(family2, segment)
    } else {
        data <- rbind(family, segment)
    }

    data <- as.data.frame(t(data), stringsAsFactors = FALSE) %>%
        dplyr::mutate(type = "DOMAIN", 
                      begin = as.numeric(start), 
                      end = as.numeric(end)) %>%
        dplyr::select(type, description = famdesc, 
                      eval = fameval, begin, end) %>%
        dplyr::mutate(entryName = id)
    # dplyr::mutate(order = n)
    return(data)
}

.runDomainSearch <- function(aaSeq, plot, progress_bar, ncores) {
    type <- entryName <- description <- begin <- id <- NULL

    # prepare URL
    url <- paste("https://www.ebi.ac.uk/Tools/hmmer/search/hmmscan")
    url.opts <- list(
        httpheader = "Expect:", httpheader = "Accept:text/xml",
        verbose = FALSE, followlocation = TRUE
    )

    # run search for each protein sequence
    output <- BiocParallel::bplapply(seq_len(nrow(aaSeq)), function(y) {
        # account for return errors
        report <- tryCatch(
            .getdomains(url, url.opts, aaSeq[y, ]$x, 
                        aaSeq[y, ]$id, nchar(aaSeq[y, ]$x), y),
            error = function(e) NULL
        )

        if (is.null(report)) {
            return(tibble::tibble(type = "CHAIN", 
                                  description = aaSeq[y, ]$id, 
                                  begin = 1, 
                                  end = nchar(aaSeq[y, ]$x), 
                                  entryName = aaSeq[y, ]$id))
        } else {
            return(dplyr::bind_rows(
                report,
                tibble::tibble(type = "CHAIN", 
                               description = aaSeq[y, ]$id, 
                               begin = 1, 
                               end = nchar(aaSeq[y, ]$x), 
                               entryName = aaSeq[y, ]$id)
            ))
        }
    }, BPPARAM = BiocParallel::MulticoreParam(progressbar = progress_bar,
                                              workers = ncores)) %>%
        dplyr::bind_rows()

    # plot protein domains if requested
    if (plot) {
        datatoplot <- output %>%
            dplyr::left_join(
                output %>%
                    dplyr::select(entryName) %>%
                    dplyr::distinct() %>%
                    dplyr::mutate(order = dplyr::row_number()),
                by = "entryName"
            )
        if (max(datatoplot$order) > 20) {
            datatoplot <- datatoplot[datatoplot$order <= 20, ]
            rlang::warn("Plotting only first 20 proteins")
        }

        print(drawProteins::draw_canvas(datatoplot) %>%
            drawProteins::draw_chains(datatoplot) %>%
            drawProteins::draw_domains(datatoplot, label_domains = FALSE) +
            ggplot2::theme_bw() + # white background
            ggplot2::theme(
                panel.grid.minor = ggplot2::element_blank(),
                panel.grid.major = ggplot2::element_blank()
            ) +
            ggplot2::theme(
                axis.ticks = ggplot2::element_blank(),
                axis.text.y = ggplot2::element_blank()
            ) +
            ggplot2::theme(panel.border = ggplot2::element_blank()))
    }

    # prepare output table
    if ("DOMAIN" %in% output$type) {
        table.out <- output %>%
            tibble::as_tibble() %>%
            dplyr::filter(type == "DOMAIN") %>%
            dplyr::select(transcript = entryName, description, 
                          eval, begin, end)

    } else {
        return(NULL)
    }
}
