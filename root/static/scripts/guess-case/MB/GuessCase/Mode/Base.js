// This file is part of MusicBrainz, the open internet music database.
// Copyright (C) 2005 Stefan Kestenholz (keschte)
// Copyright (C) 2015 MetaBrainz Foundation
// Licensed under the GPL version 2, or (at your option) any later version:
// http://www.gnu.org/licenses/gpl-2.0.txt

var i18n = require('../../../../common/i18n.js');

var utils = require('../../../utils.js');

MB.GuessCase = (MB.GuessCase) ? MB.GuessCase : {};
MB.GuessCase.Mode = (MB.GuessCase.Mode) ? MB.GuessCase.Mode : {};

/**
 * Models a GuessCase mode.
 **/
(function () {
    var self = {};

    self.fix = function (name, re, replace) {
        return { name: name, re: re, replace: replace };
    };

    // ----------------------------------------------------------------------------
    // member functions
    // ---------------------------------------------------------------------------

    self.description = "";

    self.getDescription = function () {
        /* Work around MBS-5734 */
        return self.description.replace('<a ', '<a target="_blank" ');
    };

    /**
     * Returns true if the GC script is operating in sentence mode
     **/
    self.isSentenceCaps = function () { return true; };

    // ----------------------------------------------------------------------------
    // mode specific functions
    // ---------------------------------------------------------------------------

    /**
     * Words which are always written lowercase.
     * -------------------------------------------------------
     * tma              2005-01-29              first version
     * keschte          2005-04-17              added french lowercase characters
     * keschte          2005-06-14              added "tha" to be handled like "the"
     * warp             2011-02-01              added da, de, di, fe, fi, ina, inna
     **/
    var lowerCaseWords = /^(a|an|and|as|at|but|by|da|de|di|fe|fi|for|in|ina|inna|n|nor|o|of|on|or|tha|the|to)$/;

    self.isLowerCaseWord = function (w) {
        return lowerCaseWords.test(w);
    };

    /**
     * Words which are always written uppercase.
     * -------------------------------------------------------
     * keschte          2005-01-31              first version
     * various          2005-05-05              added "FM...PM"
     * keschte          2005-05-24              removed AM,PM because it yielded false positives e.g. "I AM stupid"
     * keschte          2005-07-10              added uk,bpm
     * keschte          2005-07-20              added ussr,usa,ok,nba,rip,ny,classical words,hip-hop artists
     * keschte          2005-10-24              removed AD
     * keschte          2005-11-15              removed RIP (Let Rip) is not R.I.P.
     **/
    var upperCaseWords = /^(dj|mc|tv|mtv|ep|lp|ymca|nyc|ny|ussr|usa|r&b|bbc|fm|bc|ac|dc|uk|bpm|ok|nba|rza|gza|odb|dmx|2xlc)$/;
    var romanNumerals = /^(i|ii|iii|iv|v|vi|vii|viii|ix|x)$/;

    self.isUpperCaseWord = function (w) {
        return upperCaseWords.test(w) || (gc.CFG_UC_ROMANNUMERALS && romanNumerals.test(w));
    };

    /**
     * Pre-process to find any lowercase_bracket word that needs to be put into parentheses.
     * starts from the back and collects words that belong into
     * the brackets: e.g.
     * My Track Extended Dub remix => My Track (extended dub remix)
     * My Track 12" remix => My Track (12" remix)
     **/
    self.prepExtraTitleInfo = function (w) {
        var lastword = w.length-1, wi = lastword;
        var handlePreProcess = false;
        var isDoubleQuote = false;
        while (((w[wi] == " ") || // skip whitespace
                (w[wi] == '"' && (w[wi-1] == "7" || w[wi-1] == "12")) || // vinyl 7" or 12"
                ((w[wi+1] || "") == '"' && (w[wi] == "7" || w[wi] == "12")) ||
                (utils.isPrepBracketWord(w[wi]))) &&
               wi >= 0) {
            handlePreProcess = true;
            wi--;
        }

        // Down-N-Dirty (lastword = dirty)
        // Dance,Dance,Dance (lastword = dance) get matched by the preprocessor,
        // but are a single word which can occur at the end of the string.
        // therefore, we don't put the single word into parens.

        // trackback the skipped spaces spaces, and then slurp the
        // next word, so see which word we found.
        if (wi < lastword) {
            // the word at wi broke out of the loop above,
            // is not extra title info.
            wi++;
            while (w[wi] == " " && wi < lastword) {
                wi++; // skip whitespace
            }

            // if we have a single word that needs to be put
            // in parantheses, consult the list of words
            // were we do not do it, else continue.
            var probe = w[lastword];
            if (wi == lastword && utils.isPrepBracketSingleWord(probe)) {
                handlePreProcess = false;
            }

            if (handlePreProcess && wi > 0 && wi <= lastword) {
                var nw = w.slice(0, wi);
                if (nw[wi-1] == "(") { nw.pop(); }
                if (nw[wi-1] == "-") { nw.pop(); }
                nw[nw.length] = "(";
                nw = nw.concat(w.slice(wi,w.length));
                nw[nw.length] = ")";
                w = nw;
            }
        }
        return w;
    };

    /**
     * Take care of mis-spellings that need to be fixed before
     * splitting the string into words.
     * Note:    this function is run before release and track guess
     *                  types (not for artist)
     *
     * keschte          2005-11-10              first version
     **/
    self.preProcessTitles = function (is) {
        if (!gc.re.PREPROCESS_FIXLIST) {
            gc.re.PREPROCESS_FIXLIST = [

                // trim spaces from brackets.
                self.fix("spaces after opening brackets", /(^|\s)([\(\{\[])\s+($|\b)/i, "$2"),
                self.fix("spaces before closing brackets", /(\b|^)\s+([\)\}\]])($|\b)/i, "$2"),

                // remix variants
                self.fix("re-mix -> remix", /(\b|^)re-mix(\b)/i, "remix"),
                self.fix("re-mix -> remix", /(\b|^)re-mix(\b)/i, "remix"),
                self.fix("remx -> remix", /(\b|^)remx(\b)/i, "remix"),
                self.fix("re-mixes -> remixes", /(\b|^)re-mixes(\b)/i, "remixes"),
                self.fix("re-make -> remake", /(\b|^)re-make(\b)/i, "remake"),
                self.fix("re-makes -> remakes", /(\b|^)re-makes(\b)/i, "remakes"),
                self.fix("re-edit variants, prepare for postprocess", /(\b|^)re-?edit(\b)/i, "re_edit"),
                self.fix("RMX -> remix", /(\b|^)RMX(\b)/i, "remix"),

                // extra title information
                self.fix("alt.take -> alternate take", /(\b|^)alt[\.]? take(\b)/i, "alternate take"),
                self.fix("instr. -> instrumental", /(\b|^)instr\.?(\b)/i, "instrumental"),
                self.fix("altern. -> alternate", /(\b|^)altern\.?(\s|\)|$)/i, "alternate"),
                self.fix("orig. -> original", /(\b|^)orig\.?(\s|\)|$)/i, "original"),
                self.fix("ver(s). -> version", /(\b|^)vers?\.(\s|\)|$)/i, "version"),
                self.fix("Extendet -> extended", /(\b|^)Extendet(\b)/i, "extended"),
                self.fix("extd. -> extended", /(\b|^)ext[d]?\.?(\s|\)|$)/i, "extended"),

                // featuring variant
                self.fix("/w -> ft. ", /(\s)[\/]w(\s)/i, "ft."),
                self.fix("f. -> ft. ", /(\s)f\.(\s)/i, "ft."),
                self.fix("f/ -> ft. ", /(\s)f\/(\s)/i, "ft."),
                self.fix("'featuring - ' -> feat", /(\s)featuring -(\s)/i, "feat"),

                // without (jira ticket MBS-1312).
                self.fix("w/o -> without", /(\b|^)w[\/]o(\b)/i, "without"),

                // vinyl
                self.fix("12'' -> 12\"", /(\s|^|\()(\d+)''(\s|$)/i, "$2\""),
                self.fix("12in -> 12\"", /(\s|^|\()(\d+)in(ch)?(\s|$)/i, "$2\""),

                // combined word hacks, e.g. replace spaces with underscores,
                // (e.g. "a cappella" -> a_capella), such that it can be handled
                // correctly in post-processing
                self.fix("A Capella preprocess", /(\b|^)a\s?c+ap+el+a(\b)/i, "a_cappella"),
                self.fix("OC ReMix preprocess", /(\b|^)oc\sremix(\b)/i, "oc_remix"),
                self.fix("a.k.a. preprocess", /(\b|^)aka(\b)/ig, "a_k_a_"),
                self.fix("a.k.a. preprocess", /(\b|^)a\/k\/a(\b)/ig, "a_k_a_"),
                self.fix("a.k.a. preprocess", /(\b|^)a\.k\.a\.(\s)/ig, "a_k_a_"),

                // Handle Part/Volume abbreviations
                self.fix("Standalone Pt. -> Part", /(^|\s)Pt\.?(\s|$)/i, "Part"),
                self.fix("Standalone Pts. -> Parts", /(^|\s)Pts\.(\s|$)/i, "Parts"),
                self.fix("Standalone Vol. -> Volume", /(^|\s)Vol\.(\s|$)/i, "Volume"),

                // Get parts out of brackets
                // Name [Part 1] -> Name, Part 1
                // Name (Part 1) -> Name, Part 1
                // Name [Parts 1] -> Name, Parts 1
                // Name (Parts 1-2) -> Name, Parts 1-2
                // Name (Parts x & y) -> Name, Parts x & y
                self.fix("Pt -> , Part", /((,|\s|:|!)+)\s*(Part|Pt)[\.\s#]*((\d|[ivx]|[\-,&\s])+)(\s|:|$)/i, "Part $4"),
                self.fix("Pts -> , Parts", /((,|\s|:|!)+)\s*(Parts|Pts)[\.\s#]*((\d|[ivx]|[\-&,\s])+)(\s|:|$)/i, "Parts $4"),
                self.fix("Vol -> , Volume", /((,|\s|:|!)+)\s*(Volume|Vol)[\.\s#]*((\d|[ivx]|[\-&,\s])+)(\s|:|$)/i, "Volume $4"),
                self.fix("(Pt) -> , Part", /((,|\s|:|!)+)([\(\[])\s*(Part|Pt)[\.\s#]*((\d|[ivx]|[\-,&\s])+)([\)\]])(\s|:|$)/i, "Part $5"),
                self.fix("(Pts) -> , Parts", /((,|\s|:|!)+)([\(\[])\s*(Parts|Pts)[\.\s#]*((\d|[ivx]|[\-&,\s])+)([\)\]])(\s|:|$)/i, "Parts $5"),
                self.fix("(Vol) -> , Volume", /((,|\s|:|!)+)([\(\[])\s*(Volume|Vol)[\.\s#]*((\d|[ivx]|[\-&,\s])+)([\)\]])(\s|:|$)/i, "Volume $5"),
                self.fix(": Part -> , Part", /(\b|^): Part(\b)/i, ", part"),
                self.fix(": Parts -> , Parts", /(\b|^): Part(\b)/i, ", parts")
            ];
        }

        return self.runFixes(is, gc.re.PREPROCESS_FIXLIST);
    };

    /**
     * Collect words from processed wordlist and apply minor fixes that
     * aren't handled in the specific function.
     **/
    self.runPostProcess = function (is) {
        if (!gc.re.POSTPROCESS_FIXLIST) {
            gc.re.POSTPROCESS_FIXLIST = [

                // see combined words hack in preProcessTitles
                self.fix("a_cappella inside brackets", /(\b|^)a_cappella(\b)/, "a cappella"),
                self.fix("a_cappella outside brackets", /(\b|^)A_cappella(\b)/, "A Cappella"),
                self.fix("oc_remix", /(\b|^)oc_remix(\b)/i, "OC ReMix"),
                self.fix("re_edit inside brackets", /(\b|^)Re_edit(\b)/, "re-edit"),
                self.fix("a.k.a. lowercase", /(\b|^)a_k_a_(\b|$)/ig, "a.k.a."),

                // 'fe' is considered a lowercase word, but "Santa Fe" is very common in
                // song titles, so change that "fe" back into "Fe".
                self.fix("a.k.a. lowercase", /(\b|^)Santa fe(\b|$)/g, "Santa Fe"),

                // TODO: check if needed?
                self.fix("whitespace in R&B", /(\b|^)R\s*&\s*B(\b)/i, "R&B"),
                self.fix("[live] to (live)", /(\b|^)\[live\](\b)/i, "(live)"),
                self.fix("Djs to DJs", /(\b|^)Djs(\b)/i, "DJs"),
                self.fix("Rock 'n' Roll", /(\s|^)Rock '?n'? Roll(\s|$)/i, "Rock 'n' Roll")
            ];
        }
        var os = self.runFixes(is, gc.re.POSTPROCESS_FIXLIST);
        if (is != os) {
            is = os;
        }
        return os;
    };

    /**
     * Iterate through the list array and apply the fixes to string is
     *
     * @param is        the input string
     * @param list      the list of fix objects to apply.
     **/
    self.runFixes = function (is, list) {
        var replace_match = function (matcher, is) {
            // get reference to first set of parentheses
            var a = matcher[1] || '';

            // get reference to last set of parentheses
            var b = matcher[matcher.length-1] || '';

            // compile replace string
            var rs = [a,fix.replace,b].join("");
            return is.replace(fix.re, rs);
        };

        var matcher = null;
        var len = list.length;
        for (var i = 0; i < len; i++) {
            var fix = list[i];

            if (fix && fix.name) {
                if (fix.re.global) {
                    var matches;
                    while ((matches = fix.re.exec(is))) {
                        is = replace_match(matches, is);
                    }
                } else {
                    if ((matches = is.match(fix.re)) != null) {
                        is = replace_match(matches, is);
                    }
                }
            }
        }
        return is;
    };

    /**
     * Look for, and convert vinyl expressions
     * * look only at substrings which start with ' '  OR '('
     * * convert 7',7'',7",7in,7inch TO '7"_' (with a following SPACE)
     * * convert 12',12'',12",12in,12inch TO '12"_' (with a following SPACE)
     * * do NOT handle strings like 80's
     * Examples:
     *  Original string: "Fine Day (Mike Koglin 12' mix)"
     *          Last matched portion: " 12' "
     *          Matched portion 1 = " "
     *          Matched portion 2 = "12"
     *          Matched portion 3 = " "
     *  Original string: "Where Love Lives (Come on In) (12"Classic mix)"
     *          Last matched portion: "(12"C"
     *          Matched portion 1 = "("
     *          Matched portion 2 = "12"
     *          Matched portion 3 = "C"
     *  Original string: "greatest 80's hits"
     *          Match failed.
     **/
    self.fixVinylSizes = function (is) {
        return is
            .replace(/(\s+|\()(7|10|12)(?:inch\b|in\b|'|''|")([^s]|$)/ig, "$1$2\"$3")
            .replace(/((?:\s+|\()(?:7|10|12)")([^),\s])/, "$1 $2");
    };

    /**
     * Delegate function for Mode specific word handling.
     * This is mostly used for context based titling changes.
     *
     * @return  false, such that the normal word handling can take place for
     *          the current word, if that should not be done, return true.
     **/
    self.doWord = function () {
        return false;
    };

    MB.GuessCase.Mode.English = $.extend({}, self, {
        description: i18n.l(
            "This mode capitalises almost all words, with some words " +
            "(mainly articles and short prepositions) lowercased. Some " +
            "words may need to be manually capitalised to follow the " +
            "{url|English capitalisation guidelines}.",
            { url: "https://musicbrainz.org/doc/Style/Language/English" }
        ),

        isSentenceCaps: function () { return false }
    });

    MB.GuessCase.Mode.French = $.extend({}, self, {
        description: i18n.l(
            "This mode capitalises titles as sentence mode, but also " +
            "inserts spaces before semicolons, colons, exclamation marks " +
            "and question marks, and inside guillemets. Some words may " +
            "need to be manually capitalised to follow the {url|French " +
            "capitalisation guidelines}.",
            { url: "https://musicbrainz.org/doc/Style/Language/French" }
        ),

        runPostProcess: function (is) {
            return self.runPostProcess(is)
                .replace(/([!\?;:]+)/gi, " $1")
                .replace(/([«]+)/gi, "$1 ")
                .replace(/([»]+)/gi, " $1");
        }
    });

    MB.GuessCase.Mode.Sentence = $.extend({}, self, {
        description: i18n.l(
            "This mode capitalises the first word of a sentence, most " +
            "other words are lowercased. Some words, often proper nouns, " +
            "may need to be manually fixed according to the {url|relevant " +
            "language guidelines}.",
            { url: "https://musicbrainz.org/doc/Style/Language" }
        )
    });
}());
