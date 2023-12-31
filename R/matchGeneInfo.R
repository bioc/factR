#' Match gene metadata from query GTF to a reference GTF
#'
#' @description
#' `matchGeneInfo()` matches and corrects Gene IDs from a 
#' query GTF object to a reference GTF
#'
#' @details
#' The default approach to this correction relies on finding overlaps 
#' between transcripts in query with transcripts in reference. Using this 
#' method alone could result in false positive matches 
#' (19 percent false positives).
#' To improve this, users have the option to invoke two additional layers 
#' of matching.  
#' (1) Matching by ENSEMBL Gene_IDs. If both query and reference transcript 
#' annotations containg Ensembl-style Gene IDs, this program will try to 
#' match both IDs in a less stringent manner. This correction can be invoked
#' by providing the 'primary_gene_id' argument
#'
#' (2) Matching by secondary Gene_IDs. Depending on the transcript assembly 
#' program, GTF/GFF3 annotations may contain additional comments on the
#' transcript information. This may include a distinct secondary Gene ID 
#' annotation that potentially matches with the reference. To invoke this 
#' correction, provide 'primary_gene_id' and 'secondary_gene_id' arguments. 
#' To determine if your transcript assembly contain possible secondary 
#' Gene IDs, import query GTF file using `importGTF()` and check its metadata
#' columns
#'
#'
#' @param query
#' Query GTF imported as GRanges object
#' @param ref
#' Reference GTF as GRanges object
#' @param primary_gene_id
#' Character name of the primary gene id metadata in query GTF.
#' Input to this argument is typically 'gene_id'
#' @param secondary_gene_id
#' Character name of the secondary gene id in query file.
#' Example of input to this argument is 'ref_gene_id'
#'
#' @return
#' Gene_id-matched query GRanges
#' @export
#'
#' @examples
#' ## ---------------------------------------------------------------------
#' ## EXAMPLE USING SAMPLE DATASET
#' ## ---------------------------------------------------------------------
#' # Load datasets
#' data(chrom_matched_query_gtf, ref_gtf)
#' 
#' # Run matching function
#' matchGeneInfo(chrom_matched_query_gtf, ref_gtf)
#' @author Fursham Hamid

matchGeneInfo <- function(query, ref,
                          primary_gene_id = NULL,
                          secondary_gene_id = NULL) {

    # define global variables
    matched <- gene_id <- transcript_id <- matched <- match_level <- NULL
    type <- NULL


    # retrieve input object names and perform input chekcs
    argnames <- as.character(match.call())[-1]
    .matchgeneinfochecks(query, ref)


    # prepare a df with a list of gene_ids found in reference
    ref.genelist <- ref %>%
        as.data.frame() %>%
        dplyr::select(gene_id) %>%
        dplyr::distinct() %>%
        dplyr::mutate(matched = TRUE) 

    # convert input GRanges object to dataframe for 
    # parsing and adding meta information
    query <- query %>%
        as.data.frame() %>%
        dplyr::filter(type != "gene") %>%
        dplyr::mutate(old_gene_id = gene_id, match_level = 0) %>%
        dplyr::left_join(ref.genelist, by = "gene_id")


    # count number of non standard ID before correction
    nonstand_before <- query %>%
        dplyr::distinct(gene_id, .keep_all = TRUE) %>%
        dplyr::filter(is.na(matched)) %>%
        nrow()
    rlang::inform(italic(sprintf("    Number of mismatched gene_ids found: %s", 
                          nonstand_before)))
    
    
    ###########################################################################
    # this function will attempt to match gene_ids from input to reference
    #   there are 2 optional matching functions and 1 constitutive matching 
    #   function the optional sub-function can be invoked by providing 
    #   primary_gene_id and secondary_gene_id (matching 1)or by providing 
    #   primary_gene_id only (matching 2) depending on the the degree of 
    #   matching done, a match_level is assigned and the number represents:
    #     0 -> ids are found in ref;
    #     1 -> ids are matched by secondary_gene_id
    #     2 -> ids are matched by appending ENS... suffix
    #     3 -> ids are matched by secondary_gene_id followed by appending ENS..
    #     4 -> ids are matched by matching overlapping coordinates
    #     5 -> id could not be matched and will be skipped from analysis
    ##########################################################################
    
    # Matching function 1: replace primary_gene_id with secondary_gene_id, 
    # IF both args are provided
    if (!is.null(primary_gene_id) & !is.null(secondary_gene_id)) {
        query <- .matchfunction1(query, ref, primary_gene_id, 
                                 secondary_gene_id) 
    }

    # Matching function 2: replace primary_gene_id with basic gene ID IF:
    # at least primary_gene_id is provided and if it starts with 'ENS'
    if (!is.null(primary_gene_id)) {
        query <- .matchfunction2(query, ref, primary_gene_id)
    }
    
    # Matching function 3: correct gene_ids by finding overlapping regions.
    query <- .matchfunction3(query, ref, ref.genelist)

    # Perform post-matching functions and return object
    return(.postmatching(query, ref, nonstand_before))
}

.matchgeneinfochecks <- function(query, ref, argnames) {
    
    
    # catch unmatched seqlevels
    if (suppressWarnings(!has_consistentSeqlevels(query, ref))) {
        rlang::abort(sprintf(
            "`%s` and `%s` has unmatched seqlevel styles. 
Try running: %s <- matchChromosomes(%s, %s)",
            argnames[1], argnames[2], argnames[1], argnames[1], argnames[2]
        ))
    } else {
        outmsg <- has_consistentSeqlevels(query, ref)
    }
}

.matchfunction1 <- function(query, ref, primary_gene_id, secondary_gene_id) {
    gene_id <- matched <- match_level <- NULL
    # Matching function 1: replace primary_gene_id with secondary_gene_id, 
    #IF both args are provided
    # count number of non-standard ids before matching
    countsbefore <- query %>%
        dplyr::distinct(gene_id, .keep_all = TRUE) %>%
        dplyr::filter(is.na(matched)) %>%
        nrow()
    
    
    # proceed with matching only if there are unmatched gene ids
    if (countsbefore > 0) {
        rlang::inform(italic(sprintf(
            "    -> Attempting to correct gene ids by replacing %s with %s...",
            primary_gene_id, secondary_gene_id
        )))
        
        # prepare a df with a list of gene_ids found in reference
        ref.genelist.1 <- ref %>%
            as.data.frame() %>%
            dplyr::select(gene_id) %>%
            dplyr::distinct() %>%
            dplyr::mutate(matched = TRUE)
        
        # core of the function.
        #   this will replace the primary_gene_id with the secondary_gene_id 
        #   and change the match_level of matched transcripts to 1
        query <- suppressMessages(
            query %>% 
                dplyr::mutate(
                    !!primary_gene_id := ifelse(
                        is.na(matched) & !is.na(get(secondary_gene_id)),
                        get(secondary_gene_id), 
                        get(primary_gene_id))
                    ) %>%
                dplyr::mutate(
                    match_level = ifelse(
                        is.na(matched) & !is.na(get(secondary_gene_id)),
                        1,
                        match_level)
                              ) %>%
                dplyr::select(-matched) %>%
                dplyr::left_join(ref.genelist.1))
        
        
        # count number of non-standard ids after matching
        countsafter <- query %>%
            dplyr::distinct(gene_id, .keep_all = TRUE) %>%
            dplyr::filter(is.na(matched)) %>%
            nrow()
        if (countsafter > countsbefore) {
            countsafter <- countsbefore
        } 
        
        # report number of IDs corrected
        rlang::inform(italic(sprintf(
            "    -> %s gene_ids matched",
            (countsbefore - countsafter)
        )))
    }
    return(query)
}

.matchfunction2 <- function(query, ref, primary_gene_id) {
    gene_id <- matched <- match_level <- appended_ens_id <- NULL
    transcript_id <- basic_gene_id <- matched1 <- NULL
    # Matching function 2: replace primary_gene_id with basic gene ID IF:
    # count number of non-standard ids before matching
    countsbefore <- query %>%
        dplyr::distinct(gene_id, .keep_all = TRUE) %>%
        dplyr::filter(is.na(matched)) %>%
        nrow()
    
    # proceed with matching only if there are unmatched gene ids
    if (countsbefore > 0) {
        rlang::inform(italic("    --> Attempting to match ensembl gene_ids..."))
        # prepare a df with a list of reference gene_ids and append 
        # ENSEMBL style ids to remove suffixes
        ref.genelist.2 <- ref %>%
            as.data.frame() %>%
            dplyr::select(gene_id) %>%
            dplyr::distinct() %>%
            dplyr::mutate(matched = TRUE) %>%
            dplyr::mutate(appended_ens_id = ifelse(
                startsWith(gene_id, "ENS"),
                stringr::str_remove(gene_id, pattern = "\\.[0-9]+$"), 
                NA
            )) %>%
            dplyr::filter(!is.na(appended_ens_id)) %>%
            dplyr::select(appended_ens_id, basic_gene_id = gene_id, 
                          matched1 = matched)
        
        # core of the function.
        #   this function will append ENSEMBL style primary_gene_ids 
        #   to remove suffixes and match those gene_ids to the appended
        #   reference gene_ids and change the match_level 
        #   of matched transcripts
        query <- suppressMessages(
            query %>%
                dplyr::group_by(transcript_id) %>% 
                dplyr::mutate(appended_ens_id = ifelse(
                    startsWith(get(primary_gene_id), "ENS") & is.na(matched), 
                    stringr::str_remove(get(primary_gene_id), pattern = "\\.[0-9]+$"),
                    as.character(NA))) %>%
                dplyr::left_join(ref.genelist.2) %>%
                dplyr::mutate(!!primary_gene_id := ifelse(
                    !is.na(basic_gene_id),  
                    basic_gene_id,
                    get(primary_gene_id))) %>%
                dplyr::mutate(match_level = ifelse(
                    !is.na(basic_gene_id),match_level + 2,   match_level)) %>%
                dplyr::mutate(matched = ifelse(
                    !is.na(basic_gene_id),matched1, matched)) %>%
                dplyr::select(-appended_ens_id, -basic_gene_id, -matched1) %>%
                dplyr::ungroup())
        
        # count number of non-standard ids after matching
        countsafter <- query %>%
            dplyr::distinct(gene_id, .keep_all = TRUE) %>%
            dplyr::filter(is.na(matched)) %>%
            nrow()
        
        # print out statistics of the match
        #   or print out warning if none of the genes were matched
        if (countsbefore > countsafter) {
            rlang::inform(italic(sprintf("    --> %s gene_ids matched", 
                                  (countsbefore - countsafter))))
        } else {
            anyEnsid <- query %>%
                dplyr::select(gene_id) %>%
                dplyr::distinct() %>%
                dplyr::filter(startsWith(gene_id, "ENS")) %>%
                nrow() > 0
            
            if (anyEnsid == TRUE) {
                rlang::inform(italic(
                    "    --> All ensembl gene ids have been matched"))
            } else {
                rlang::inform(italic(
                    "    --> No ensembl gene ids found in query"))
            }
        }
    }
    return(query)
}

.matchfunction3 <- function(query, ref, ref.genelist) {
    gene_id <- matched <- match_level <- unmatched_granges.start <- NULL
    transcript_id <- basic_gene_id <- matched1 <- type <- NULL
    seqnames <- strand <- unmatched_granges.end <- ref.end <- NULL
    ref.start <- basic_gene_id <- NULL
    
    # Matching function 3: correct gene_ids by finding overlapping regions.
    
    # count number of unmatched ids before matching
    countsbefore <- query %>%
        dplyr::distinct(gene_id, .keep_all = TRUE) %>%
        dplyr::filter(is.na(matched)) %>%
        nrow()
    
    if (countsbefore == 0) {
        rlang::inform(italic("    --> All gene ids have been matched"))
    } else {
        rlang::inform(italic(paste0("    ---> Attempting to match gene_ids by" ,
                             " finding overlapping coordinates...")))
        # core of the function.
        #   this function will gather all unmatched transcripts
        #   and attempt to find its overlap with the reference
        #   and match those gene_ids to the reference gene_ids
        #   and change the match_level of matched transcripts
        unmatched_df <- query %>%
            dplyr::filter(is.na(matched), type == "transcript") %>%
            dplyr::distinct(transcript_id, .keep_all = TRUE) %>%
            dplyr::select(seqnames, start, end, strand, transcript_id)
        unmatched_granges <- GenomicRanges::makeGRangesFromDataFrame(
            unmatched_df, keep.extra.columns = TRUE)
        
        matched_df <-  suppressWarnings(IRanges::mergeByOverlaps(unmatched_granges, ref) %>%
            as.data.frame() %>%
            dplyr::mutate(offset = abs(unmatched_granges.end - ref.end) + 
                              abs(unmatched_granges.start - ref.start)) %>%
            dplyr::arrange(offset) %>%
            dplyr::select(transcript_id, basic_gene_id = gene_id) %>%
            dplyr::distinct(transcript_id, .keep_all = TRUE))
        
        query <- suppressMessages(
            query %>%  
                dplyr::select(-matched) %>%
                dplyr::left_join(matched_df) %>%
                dplyr::mutate(gene_id = ifelse(
                    !is.na(basic_gene_id),basic_gene_id, gene_id)) %>%
                dplyr::mutate(match_level = ifelse(
                    !is.na(basic_gene_id),4, match_level)) %>%
                dplyr::select(-basic_gene_id) %>%
                dplyr::left_join(ref.genelist))
        
        # count number of unmatched ids after matching
        countsafter <- query %>%
            dplyr::distinct(gene_id, .keep_all = TRUE) %>%
            dplyr::filter(is.na(matched)) %>%
            nrow()
        
        
        # report statistics of the match
        rlang::inform(italic(sprintf("    ---> %s gene_id matched", 
                              (countsbefore - countsafter))))
    }
    return(query)
}

.postmatching <- function(query, ref, nonstand_before) {
    matched <- match_level <- gene_id <- gene_name <- ref_gene_name <- NULL
    ## post matching function
    # annotate the match_level on unmatched gene_ids
    # and cleanup the dataframe
    query <- query %>%
        dplyr::mutate(match_level = ifelse(is.na(matched),
                                           5, match_level
        )) %>%
        dplyr::select(-matched)
    
    if ("gene_name" %in% names(S4Vectors::mcols(ref))) {
        ref.genelist.1 <- ref %>%
            as.data.frame() %>%
            dplyr::select(gene_id, ref_gene_name = gene_name) %>%
            dplyr::distinct()
        
        query <- query %>%
            dplyr::left_join(ref.genelist.1, by = "gene_id") %>%
            dplyr::mutate(gene_name = ref_gene_name) %>%
            dplyr::select(-ref_gene_name)
    }
    
    # report pre-testing analysis and return query
    nonstand_after <- query %>%
        dplyr::distinct(gene_id, .keep_all = TRUE) %>%
        dplyr::filter(match_level == 5) %>%
        nrow()
    corrected_ids <- nonstand_before - nonstand_after
    
    rlang::inform(italic(sprintf("    Total gene_ids corrected: %s", corrected_ids)))
    rlang::inform(italic(sprintf("    Remaining number of mismatched gene_ids: %s", 
                          nonstand_after)))
    
    query <- GenomicRanges::makeGRangesFromDataFrame(query, 
                                                     keep.extra.columns = TRUE)
    return(query)
}
