//! Function index of Rust / Verus source files, from the Verus fork of syn.
//! Used only to name functions in reports and to find their source lines
//! for selectors (design.md, 结论20, 21).
//!
//! Usage: item-index <file.rs>...
//! For every function (free, in an impl block, or declared in a trait) and
//! every `assume_specification`, including those inside `verus! { ... }`,
//! prints
//!
//!   (item (file "...") (name "f") (start L) (end L)
//!         (self "Type" | #f) (trait "Trait" | #f) (in-trait "Trait" | #f))
//!
//! `start` and `end` are the lines of the whole item, attributes included.
//! `self` and `trait` are the impl block's self type and implemented trait,
//! as written in the source; `in-trait` is set for trait method
//! declarations.  Only signatures and positions are read, never function
//! bodies.  Files that cannot be read or parsed are reported on stderr.

use quote::ToTokens;
use verus_syn::{spanned::Spanned, ImplItem, Item, TraitItem, Type};

fn main() {
    let mut out = String::new();
    for path in std::env::args().skip(1) {
        let Ok(src) = std::fs::read_to_string(&path) else { eprintln!("{path}: cannot read"); continue };
        match verus_syn::parse_file(&src) {
            Ok(f) => walk(&path, &f.items, &mut out),
            Err(e) => eprintln!("{path}: parse error: {e}"),
        }
    }
    print!("{out}");
}

fn s(t: &str) -> String {
    let mut r = String::from("\"");
    for c in t.chars() {
        match c { '"' => r.push_str("\\\""), '\\' => r.push_str("\\\\"), '\n' | '\r' => r.push(' '), c => r.push(c) }
    }
    r.push('"');
    r
}

/// Token text with the spaces `to_string` puts around punctuation removed.
fn text<T: ToTokens>(t: &T) -> String {
    let raw = t.to_token_stream().to_string();
    let mut r = raw.replace(" < ", "<").replace("< ", "<").replace(" >", ">").replace(" ,", ",")
        .replace(" :: ", "::").replace(":: ", "::").replace(" ::", "::").replace("& ", "&")
        .replace("' ", "'").replace(" (", "(").replace("( ", "(").replace(" )", ")");
    while r.contains("  ") { r = r.replace("  ", " "); }
    r
}

fn opt(o: &Option<String>) -> String {
    match o { Some(t) => s(t), None => "#f".into() }
}

fn emit(out: &mut String, path: &str, name: &str, span: proc_macro2::Span,
        self_ty: Option<&Type>, tr: Option<String>, in_trait: Option<String>) {
    out.push_str(&format!(
        "(item (file {}) (name {}) (start {}) (end {}) (self {}) (trait {}) (in-trait {}))\n",
        s(path), s(name), span.start().line, span.end().line,
        opt(&self_ty.map(text)), opt(&tr), opt(&in_trait)));
}

fn is_verus(m: &verus_syn::ItemMacro) -> bool {
    m.mac.path.segments.last().map_or(false, |seg| seg.ident == "verus")
}

fn walk(path: &str, items: &[Item], out: &mut String) {
    for item in items {
        match item {
            Item::Fn(f) => emit(out, path, &f.sig.ident.to_string(), f.span(), None, None, None),
            // Verus turns an `exec static` into a function of the same name
            Item::Static(st) => emit(out, path, &st.ident.to_string(), st.span(), None, None, None),
            // named in VIR by the external function's path; its last segment
            // is the name
            Item::AssumeSpecification(a) => {
                if let Some(seg) = a.path.segments.last() {
                    emit(out, path, &seg.ident.to_string(), a.span(), None, None, None)
                }
            }
            Item::Impl(i) => {
                let tr = i.trait_.as_ref().map(|(_, p, _)| text(p));
                for it in &i.items {
                    if let ImplItem::Fn(f) = it {
                        emit(out, path, &f.sig.ident.to_string(), f.span(), Some(&i.self_ty), tr.clone(), None);
                    }
                }
            }
            Item::Trait(t) => {
                for it in &t.items {
                    if let TraitItem::Fn(f) = it {
                        emit(out, path, &f.sig.ident.to_string(), f.span(), None, None, Some(t.ident.to_string()));
                    }
                }
            }
            Item::Mod(m) => {
                if let Some((_, inner)) = &m.content {
                    walk(path, inner, out);
                }
            }
            // the body of `verus! { ... }` is itself a sequence of items.
            // Like the macro itself, first rejoin the tokens that Verus
            // reads as one (e.g. `!is` becomes `isnt`, `!has` `hasnt`).
            Item::Macro(m) if is_verus(m) => {
                match verus_syn::parse2::<verus_syn::File>(verus_syn::rejoin_tokens(m.mac.tokens.clone())) {
                    Ok(f) => walk(path, &f.items, out),
                    Err(e) => {
                        let at = e.span().start();
                        eprintln!("{path}:{}:{}: verus! parse error: {e}", at.line, at.column + 1)
                    }
                }
            }
            _ => {}
        }
    }
}
