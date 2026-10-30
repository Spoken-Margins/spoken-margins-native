package weborigin

import "testing"

func TestValid(t *testing.T) {
	good := []string{
		"https://web.example.com",
		"https://web.example.com:8443",
		"https://xn--bcher-kva.example",
		"https://[2001:db8::1]",
		"http://localhost:5173",
		"http://127.0.0.1:5173",
		"http://localhost",
	}
	for _, s := range good {
		if !Valid(s) {
			t.Errorf("%q should be valid", s)
		}
	}
	bad := []string{
		"",
		"null",
		"*",
		"https://*.example.com",
		"https://web.example.com/",
		"https://web.example.com/app",
		"https://web.example.com?x=1",
		"https://web.example.com?",
		"https://web.example.com#x",
		"https://web.example.com:",
		"https://web.example.com:443",
		"http://localhost:80",
		"HTTPS://web.example.com",
		"https://Web.Example.com",
		"https://user@web.example.com",
		"https://user:pw@web.example.com",
		"http://web.example.com",
		"ftp://web.example.com",
		"web.example.com",
		"//web.example.com",
		"https://bücher.example",
		" https://web.example.com",
		"https://web.example.com ",
		"https://web.example.com\t",
		"https://",
	}
	for _, s := range bad {
		if Valid(s) {
			t.Errorf("%q should be refused", s)
		}
	}
}

func TestParse(t *testing.T) {
	got, err := Parse("https://web.example.com, http://localhost:5173")
	if err != nil || len(got) != 2 || got[0] != "https://web.example.com" || got[1] != "http://localhost:5173" {
		t.Fatalf("got %v %v", got, err)
	}
	if got, err := Parse(""); err != nil || got != nil {
		t.Fatalf("empty list: got %v %v", got, err)
	}
	for _, bad := range []string{"https://web.example.com,*", "https://web.example.com/", "https://ok.example,", "null", ","} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("%q should be refused", bad)
		}
	}
}

func TestAllowedIsExact(t *testing.T) {
	list := []string{"https://web.example.com"}
	if !Allowed(list, "https://web.example.com") {
		t.Fatal("listed origin refused")
	}
	for _, o := range []string{
		"", "null",
		"HTTPS://web.example.com", "https://WEB.example.com",
		"https://web.example.com/", "https://web.example.com:443", "https://web.example.com:8443",
		"http://web.example.com", "https://web.example.com.evil.example", "https://evilweb.example.com",
		"https://sub.web.example.com",
	} {
		if Allowed(list, o) {
			t.Errorf("%q should not match", o)
		}
	}
	if Allowed(nil, "https://web.example.com") {
		t.Error("an empty list allows nothing")
	}
}
