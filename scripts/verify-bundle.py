#!/usr/bin/env python3
"""Check built share-extension wiring; does not prove Safari discovery or delivery."""
import argparse
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def inspect_bundle(app):
    with (app / 'Info.plist').open('rb') as source:
        info = plistlib.load(source)
    exported = {item['UTTypeIdentifier'] for item in info.get('UTExportedTypeDeclarations', [])}
    if 'com.spokenmargins.package' not in exported:
        raise ValueError('Built app does not export the package UTI')
    extension = app / 'PlugIns/SpokenMarginsShareExtension.appex'
    with (extension / 'Info.plist').open('rb') as source:
        metadata = plistlib.load(source)['NSExtension']
    if metadata['NSExtensionPointIdentifier'] != 'com.apple.share-services':
        raise ValueError('Wrong share extension point')
    principal = metadata['NSExtensionPrincipalClass']
    if '$(' in principal or not principal.endswith('.SourceLinkShareViewController'):
        raise ValueError('Unresolved or wrong share principal class')
    attributes = metadata['NSExtensionAttributes']
    rule = attributes['NSExtensionActivationRule']
    for identifier in ('com.spokenmargins.package', 'com.adobe.pdf', 'public.url', 'public.text', 'com.apple.property-list'):
        if f'UTI-CONFORMS-TO "{identifier}"' not in rule:
            raise ValueError(f'Activation metadata omits {identifier}')
    resource = extension / (attributes['NSExtensionJavaScriptPreprocessingFile'] + '.js')
    if not resource.is_file():
        raise ValueError('Declared Safari preprocessing resource is absent from built extension')
    return resource


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    resource = inspect_bundle(args.app)
    subprocess.run(['node', str(ROOT / 'scripts/check-share-preprocessor.cjs'), str(resource)], check=True, timeout=15)
    print('Built app UTI and share-extension metadata: passed')


if __name__ == '__main__':
    main()
