var SourceLinkPreprocessor = function() {};

SourceLinkPreprocessor.prototype = {
    run: function(arguments) {
        var canonical = "";
        var canonicalElement = document.querySelector("link[rel='canonical']");
        if (canonicalElement) {
            canonical = canonicalElement.href || "";
        }
        arguments.completionFunction({
            "url": window.location.href,
            "documentURL": document.URL,
            "canonicalURL": canonical,
            "title": document.title || ""
        });
    },

    finalize: function(arguments) {}
};
