#' Generate Rust bindings
#' @param pkgdir package path
#' @export
rustrize <- function(pkgdir = ".") {
    libpath = "src/rustlib"
    pkgdir <- normalizePath(pkgdir, winslash = "/")
    descfile <- file.path(pkgdir, "DESCRIPTION")
    if (!file.exists(descfile))
        stop("Can not find DESCRIPTION.")
    pkgdesc <- read.dcf(descfile)[1,]
    rustdir <- file.path(pkgdir, libpath, "src")
    cdir <- file.path(pkgdir, "src")
    if (!file.exists(rustdir))
        stop("Can not find Rust source path")
    if (!file.exists(cdir))
        dir.create(cdir)
    rdir <- file.path(pkgdir, "R")
    if (!file.exists(rdir))
        dir.create(rdir)
    rustfiles1 <- list.files(rustdir, pattern = "\\.rs$")
    rustfiles11 <- rustfiles1[rustfiles1 != "export.rs"]
    rustfiles2 <- file.path(rustdir, rustfiles11)
    rustfiles <- normalizePath(rustfiles2, winslash = "/")
    # we now get all the rust files
    info = list(
        rustfiles = rustfiles,
        rdir = rdir,
        rustdir = rustdir,
        cdir = cdir,
        pkgdesc = pkgdesc
    )

    # init function info enviroment
    res = new.env(parent = emptyenv())
    res$incomment = F
    res$sym = NULL
    res$roxlist = list() # simple roxygen comment
    res$roxbuffer = character()

    res$funclist = list()

    # get all the information after this line
    lapply(info$rustfiles, rtag_one_file_block, res)

    # return(invisible(list(info = info, res = res)))

    # code gen and write
    write_rc_file(info, res)

    return(invisible(TRUE))
}

write_rc_file = function(info, res) {
    cpath = file.path(info$cdir, "REXPORT.c")
    rpath = file.path(info$rdir, "REXPORT.R")
    rustpath = file.path(info$rustdir, "export.rs")
    if (!file.exists(cpath))
        file.create(cpath)
    if (!file.exists(rpath))
        file.create(rpath)
    if (!file.exists(rustpath))
        file.create(rustpath)
    pkgname = info$pkgdesc[names(info$pkgdesc) == "Package"]
    funres = new.env(parent = emptyenv())
    funres$c_all = character()
    funres$r_all = character()
    funres$rust_all = character()

    for (xs in res$funclist) {
        gen_fun(xs, pkgname, funres)
    }

    cfile = file(cpath, "w")
    rfile = file(rpath, "w")
    rustfile = file(rustpath, "w")

    tryCatch({
        # c
        writeLines(c("#include <Rinternals.h>\n#include <R.h>\n"), cfile)
        writeLines(funres$c_all, cfile)
        # r
        writeLines(funres$r_all, rfile)
        # rust
        writeLines(c("use super::*;\n"), rustfile)
        writeLines(funres$rust_all, rustfile)
    }, finally = {
        close(cfile)
        close(rfile)
        close(rustfile)
    })

    return(funres)
}

get_typehead = function(input) {
    res = character(length(input))

    for (xs in 1:length(input)) {
        set = FALSE
        xsx = strsplit(input[xs], "")[[1]]
        for (i in 1:length(xsx)) {
            if (xsx[i] == "<") {
                res[xs] = substr(input[xs], 1, i - 1)
                set = TRUE
                break
            }
        }
        if (set == TRUE)
            next
        res[xs] = input[xs]
    }

    return(res)
}

get_ref_info = function(input){
    input = trimws(input)

    res = character(length(input))
    mut = ref = logical(length(input))

    for (xs in 1:length(input)) {
        if (nchar(input[xs]) > 1 && substr(input[xs],0,1) == "&") {
            ref[xs] = TRUE
            trim_ref = trimws(substr(input[xs], 2, nchar(input[xs])))
            if ( nchar(trim_ref) > 3 && substr(trim_ref,1,3) == "mut" ) {
                mut[xs] = TRUE
                res[xs] = substr(trim_ref, 4, nchar(trim_ref))
            } else {
                mut[xs] = FALSE
                res[xs] = trim_ref
            }
        } else {
            mut[xs] = ref[xs] = FALSE
            res[xs] = input[xs]
        }
    }
    list(mut = mut, ref = ref, type = res)
}

gen_fun = function(funclist, pkgname, funres) {
    # new info list
    # list( name = funcp, param = paramp, type = typep, ret = retp, rettype = rettype, roxchunk = res$roxbuffer)
    if (funclist$ret == TRUE) {
        rets = "SEXP"
        unwrapr = "unwrapr!( "
        rust_tail = "return res_sexp;\n}\n"
    } else{
        rets = "SEXP"
        unwrapr = "unwrapr_void!( "
        rust_tail = "}\n"
    }

    if (length(funclist$rettype) != 0 && grepl("(RResult<)|(RR<)",funclist$rettype)){
        throw = TRUE
    } else{
        throw = FALSE
    }

    # head of c file extern rustr_func_name(
    extern_head = sprintf("extern %s rustr_%s(", rets, funclist$name)

    # head of c file call rustr_func_name(
    extern_call = sprintf("rustr_%s(", funclist$name)
    if (is.null(funclist$param) || length(funclist$param) ==0 ) {
        extern_param = ""
        rust_param = ""
        rust_param_call = ""
        rust_let = ""
    }
    else {
        extern_param = paste(paste("SEXP", funclist$param),
                             collapse = ", ",
                             sep = " ")
        #  rustr_name(a : SEXP, b : SEXP) -> SEXP or void
        rust_param = paste(paste(paste(funclist$param, "SEXP", sep = " : "), collapse = ", "))

        # [1] "let a_ : NumVec = unwrapr!( a.fromr() );\n"
        # [2] "let b_ : Int = unwrapr!( b.fromr() );\n"
        ref_info = get_ref_info(funclist$type)

        # name(a_,b_)
        param_ = paste(funclist$param, "_", sep = "")
        mut_param = funclist$param

        for (xs in 1:length(param_)) {
            if (ref_info[["ref"]][xs] == TRUE){
                if (ref_info[["mut"]][xs] == TRUE){
                    param_[xs] = paste("&mut", param_[xs])
                    mut_param[xs] = paste("mut", mut_param[xs])
                } else {
                    param_[xs] = paste("&", param_[xs])
                }
            }
        }

        rust_param_call = paste(param_, sep = " ", collapse = ",")

        typehead = get_typehead(ref_info$type)
        rust_let = paste(
            "let ",
            mut_param,
            "_ : ",
            ref_info$type,
            " = ",
            unwrapr
            ,
            typehead,
            "::rnew(",
            funclist$param,
            ") );\n",
            sep = ""
        )
    }

    # handle rust code gen

    if (funclist$ret == FALSE) {
        # name(a_,b_); call
        rust_res = paste0(funclist$name, "(", rust_param_call, ");\n\n")
        rust_head = sprintf(
            "#[no_mangle]\npub extern \"C\" fn rustr_%s(%s){\n\n",
            funclist$name,
            rust_param
        )
    } else{
        if (throw == TRUE){
        rust_res = sprintf(
            "let res  = %s%s(%s));\n\n let res_sexp : SEXP = unwrapr!(res.intor());\n\n",
            unwrapr,
            funclist$name,
            rust_param_call
        )
        } else{ # not throw
            rust_res = sprintf(
                "let res  = %s(%s);\n\n let res_sexp : SEXP = unwrapr!(res.intor());\n\n",
                funclist$name,
                rust_param_call
            )
        }
        rust_head = sprintf(
            "#[no_mangle]\npub extern \"C\" fn rustr_%s(%s)->SEXP{\n\n",
            funclist$name,
            rust_param
        )
    }

    rust_all = paste(rust_head,
                     paste(rust_let, collapse = "\n"),
                     rust_res,
                     rust_tail,
                     collapse = "\n\n")
    if (getOption("verbose")) {
        cat(rust_all)
    }
    # c code gen

    extern = sprintf("%s%s);", extern_head, extern_param)

    cfun_head = sprintf("%s %s_%s(", rets, pkgname, funclist$name)
    c_param = paste(funclist$param, collapse = ",")

    # c r code gen

    if (is.null(funclist$param) || length(funclist$param) == 0) {
        c_param = ""
        if (funclist$ret == TRUE &&
            funclist$rettype != "RResult<()>") {
            r_head = sprintf(
                "%s = function(%s){ .Call('%s_%s',PACKAGE = '%s')}",
                funclist$name,
                c_param,
                pkgname,
                funclist$name,
                pkgname
            )
        } else{
            r_head = sprintf(
                "%s = function(%s){ invisible(.Call('%s_%s',PACKAGE = '%s'))}",
                funclist$name,
                c_param,
                pkgname,
                funclist$name,
                pkgname
            )

        }
    }
    else {
        c_param = paste(funclist$param, collapse = ",")
        if (funclist$ret == TRUE &&
            funclist$rettype != "RResult<()>") {
            r_head = sprintf(
                "%s = function(%s){ .Call('%s_%s',PACKAGE = '%s', %s)}",
                funclist$name,
                c_param,
                pkgname,
                funclist$name,
                pkgname,
                c_param
            )
        } else{
            r_head = sprintf(
                "%s = function(%s){ invisible(.Call('%s_%s',PACKAGE = '%s', %s))}",
                funclist$name,
                c_param,
                pkgname,
                funclist$name,
                pkgname,
                c_param
            )
        }
    }

    if (is.null(funclist$roxchunk))
        r_all = r_head
    else
        r_all = paste(paste(funclist$roxchunk,collapse = "\n"),
                      r_head,
                      sep = "\n",
                      collapse = "\n")

    if (funclist$ret == TRUE) {
        c_fun = sprintf("%s%s){ return(%s%s));}",
                        cfun_head,
                        extern_param,
                        extern_call,
                        c_param)
        c_all = paste(extern, c_fun, sep = "\n", collapse = "\n")
    } else{
        c_fun = sprintf(
            "%s%s){ %s%s);return(R_NilValue);}",
            cfun_head,
            extern_param,
            extern_call,
            c_param
        )
        c_all = paste(extern, c_fun, sep = "\n", collapse = "\n")
    }




    funres$r_all = append(funres$r_all, r_all)
    funres$c_all = append(funres$c_all, c_all)
    funres$rust_all = append(funres$rust_all, rust_all)
}

isroxygen = function(strings) {
    len = nchar(strings[1])
    if (len < 3)
        return(FALSE)
    idx = as.numeric(regexec("\\S", strings[1])[[1]])
    if (idx == -1)
        return(FALSE)
    spstr = strsplit(strings[1], "")[[1]]
    if (length(spstr) < idx + 3)
        return(FALSE)
    if (substr(strings[1], idx, idx + 3) == "// \'") {
        return(TRUE)

    }
    return(FALSE)
}

# /**// //
# strip_trailing_comments(c("// sdsdd // sdsd","hj", "//@ "))
strip_trailing_comments = function(strings, trail = TRUE) {
    res = vector("character", length(strings))
    for (x in 1:length(strings)) {
        tmp = strings[x]
        if (tmp == "") {
            res[x] = tmp
            next

        }
        if (isroxygen(tmp)) {
            res[x] = tmp
            next

        }
        instring = FALSE
        idx = as.numeric(regexec("\\S", tmp)[[1]])
        if (idx == -1) {
            res[x] = tmp
            next

        }
        len = nchar(tmp)
        spstr = strsplit(tmp, "")[[1]]

        if (trail == TRUE) {
            if (idx + 1 < len &&
                spstr[idx] == '/' && spstr[idx + 1] == '/')         {
                idx = idx + 2

            }
        }

        set = FALSE
        lastch = 0
        while (idx < len) {
            if (instring) {
                if (spstr[idx] == '"' && spstr[idx - 1] != '\\') {
                    instring = FALSE

                }
            } else {
                if (spstr[idx] == '"') {
                    instring = TRUE

                }
            }

            if (!instring &&
                spstr[idx] == '/' &&
                spstr[idx + 1] == '/' && lastch != "*") {
                res[x] = substr(tmp, 1, idx - 1)

                set = TRUE
                break

            }
            idx = idx + 1

            lastch = spstr[idx]
        } # end while
        if (set == TRUE) {
            next
        } else {
            res[x] = tmp

            next

        }
    }
    return(res)
}

check_comment = function(line, res) {
    pos = 1
    nc = nchar(line[1])
    while (pos < nc && pos != -1) {
        # check for a //
        linecommentpos = regexec("//", line)[[1]]

        # look for the next token
        token = ifelse(res$incomment, "\\*/", "/\\*")
        pp = regexec(token, substr(line, pos, nchar(line)))[[1]]
        pos = pos + pp - 1


        # process the comment token
        if (pp != -1) {
            # break if the line comment precedes the comment token
            if (linecommentpos != -1 && linecommentpos < pos)
                break

            res$incomment = !res$incomment
            pos = pos + nchar(token)

        }
    }
}

parse_def = function(linenum, res, content) {
    # Look for the signature termination ({ or ; not inside quotes)
    # on this line and then subsequent lines if necessary
    signature = character()
    for (i in linenum:length(content)) {
        line = content[i]

        if (line == "")
            next
        insidequotes = FALSE

        prevchar = 0

        nc = nchar(line)
        spstr = strsplit(line, "")[[1]]
        # scan for { or ; not inside quotes
        for (xs in 1:nc) {
            ch = spstr[xs]
            # update quotes state
            if (ch == '"' && prevchar != '\\')
                insidequotes = !insidequotes

            # found signature termination, append and return
            if (!insidequotes && ((ch == '{') || (ch == ';'))) {
                signature = append(signature, substr(line, 0, xs - 1))

                return(signature)
            }
            # record prev char (used to check for escaped quote i.e. \")
            prevchar = ch

        }
        # if we didn't find a terminator on this line then just append the line
        # and move on to the next line
        signature = append(signature, line)

    }

    return(character())

}

parse_param_with_comma = function(string) {
    # string = "HashMap<u64,u64>,b"
    nc = nchar(string)
    split_string = strsplit(string, split = "")[[1]]
    xs = nc + 1
    for (x in nc:1) {
        if (split_string[x] == ",") {
            xs = x
            break

        }
    }

    if (xs == nc + 1) {
        warning(paste("parsing parameter fail: ", string))
    }

    c(
        type_ = substr(string, start = 1, stop = xs - 1),
        name_ = substr(string, start = xs + 1, stop = nc)
    )
}

parse_func_inner = function(linenum, res, content) {
    def = strip_trailing_comments(parse_def(linenum, res, content), FALSE)
    if (is.null(def)) {
        warning(paste("no function found1: line ", linenum, content[linenum]))
        return(NULL)
    }
    # remove block comment
    defs = gsub("\\/\\*.*\\*\\/", "", paste(trimws(def), sep = " ", collapse = ""))

    endparenloc = regexec('\\)', defs)[[1]]
    beginparenloc = regexec('\\(', defs)[[1]]

    if (endparenloc == -1 ||
        beginparenloc == -1 ||
        endparenloc < beginparenloc) {
        warning(paste("no function found2: line ", linenum, content[linenum]))
        return(NULL)
    }

    # func name
    mfuncp = regexpr("pub\\s*fn\\s*(?<first>\\w*)\\(", defs, perl = TRUE)
    funcp = parse.one(defs, mfuncp)[[1]]


    if (is.null(funcp) || is.na(funcp) || funcp == "") {
        warning(
            paste(
                "function mark as exported, but not included in export.rs",
                defs,
                sep = "\n"
            )
        )
        return(NULL)
    }

    # namep = re2_match("(\\s*\\w+\\s*:\\s*\\w+\\s*)",defs, value = TRUE, all= TRUE)[[2]]

    # defs = "pub fn map64(a:HashMap<u64,u64>,b:HashMap<u64,u64>)->RResult<HashMap<u64,u64>>"
    #
    # "a:HashMap<u64,u64>,b:HashMap<u64,u64>"
    # parampart = re2_match("\((.*)\)(?!>)*", defs , value = TRUE)[[1]]
    m = regexpr("\\((.*)\\)(?!>)", defs, perl = TRUE)
    parampart = regmatches(defs, m)[[1]][1]
    parampart = substr(parampart, 2, nchar(parampart) - 1)

    if (getOption("verbose")) {
        cat(paste0("def : ", defs, "\nparameter : \n"))
        print(parampart)
        cat("\n\n")
    }
    # paramp and typep
    if (is.na(parampart) || parampart == "") {
        paramp = NULL
        typep = NULL
    }
    else{
        # "a","HashMap<u64,u64>,b","HashMap<u64,u64>"
        namep  = strsplit(parampart, ":")[[1]]

        if (length(namep) <= 2) {
            if (length(namep) < 2) {
                warning(paste("failed to parse parameter: ", is.na(parampart)))
            } else{
                split_namep = list(namep)
            }

        } else{
            split_namep = vector("list", length = length(namep) - 1)
            part1 = parse_param_with_comma(namep[2])
            split_namep[[1]] = c(namep[1], part1[1])

            # handle middle of param list
            if (length(namep) >= 4) {
                for (ii in 2:(length(namep) - 2)) {
                    part_front = parse_param_with_comma(namep[ii])
                    part_back = parse_param_with_comma(namep[ii + 1])
                    split_namep[[ii]] = c(part_front[2], part_back[1])
                } # end for
            } # end length(namep)>4

            # handle end of param list
            partend = parse_param_with_comma(namep[length(namep) - 1])
            split_namep[[length(namep) - 1]] =
                c(partend[2],
                  namep[length(namep)])
        }


        # [[1]]
        # [1] "sd" "aa"

        # [[2]]
        # [1] "sd" "ws"
        #split_namep = lapply(strsplit(namep,":"), trimws)

        paramp = character(length = length(split_namep))
        typep = character(length = length(split_namep))
        for (xs in 1:length(split_namep)) {
            paramp[xs] = split_namep[[xs]][1]
            typep[xs] = split_namep[[xs]][2]
        }
    }

    if (grepl("\\)\\s*->\\s*(.*)", defs)) {
        mrettype = regexpr("\\)\\s*->\\s*(?<first>.*)", defs, perl = T)
        rettype = parse.one(defs, mrettype)[[1]]
        retp = TRUE
    } else if (grepl("\\)\\s*$", defs)) {
        rettype = NULL
        retp = FALSE
    } else{
        warning(paste("can not match any pattern : ", defs))
        return(NULL)
    }
    # if(is.na(namep[1])){
    #     paramp = NULL
    # }

    func = list(
        name = trimws(funcp),
        param = trimws(paramp),
        type = trimws(typep),
        ret = trimws(retp),
        rettype = trimws(rettype),
        roxchunk = res$roxbuffer
    )
    res$roxbuffer = character()
    return(func)
    # list( name = "func_name", param = c("param1","param2"), ret = TRUE)
}

parse_func = function(linenum, res, content) {
    if ((linenum + 1) <= length(content)) {
        func = parse_func_inner(linenum + 1, res, content)
        if (getOption("verbose")) {
            cat("funcion information :\n")
            print(func)
            cat("\n")
        }
        if (!is.null(func))
            res$funclist = append(res$funclist, list(func))
    }
    else {
        warning(paste("no function found3: line ", linenum, content[linenum]))
    }
}

rtag_one_file_block = function(filename, res) {
    # export pattern
    export_tag = "^\\s*\\/\\/\\s*\\#\\[rustr_export\\]\\s*"
    content = suppressWarnings(strip_trailing_comments(readLines(filename)))
    # get all no mangle start line
    # start_line = (1:length(content))[re2_match(no_mangle_tag, content)]
    # sizes = length(start_line)

    # res = new.env(parent = emptyenv())
    res$incomment = F
    res$sym = NULL
    # res$roxlist = list() # simple roxygen comment
    # res$roxbuffer = character()

    # res$funclist = list() # func with roxygen comment
    # list( name = "func_name", param = c("param1","param2"), ret = TRUE)

    for (xs in 1:length(content)) {
        line = content[xs]

        check_comment(line, res)

        if (res$incomment)
            next

        if (grepl(export_tag, content[xs])) {
            parse_func(xs, res, content)
        } else {
            # a rox comment
            if ((regexec('// \'', line)[[1]] == 1) == TRUE) {
                roxline = paste("#'" , substr(line, 5, nchar(line)), sep = "")

                res$roxbuffer = append(res$roxbuffer, roxline)
            } else {
                # a non-roxygen line causes us to clear the roxygen buffer
                #print(res$roxbuffer)
                #print(is.null(res$roxbuffer))
                if (!is.null(res$roxbuffer)) {
                    # push back a chunck of roxygen comment
                    res$roxlist = append(res$roxlist, list(res$roxbuffer))
                    # reset buffer
                    res$roxbuffer = character()
                }
            }
        }
    }
    return(res)
}

parse.one <- function(res, result) {
    m <- do.call(rbind, lapply(seq_along(res), function(i) {
        if (result[i] == -1)
            return("")
        st <- attr(result, "capture.start")[i,]
        substring(res[i], st, st + attr(result, "capture.length")[i,] - 1)
    }))
    colnames(m) <- attr(result, "capture.names")
    m
}
