process EXTRACT_MARKERS {
    tag "$meta.id"
    label 'process_single'

    container "docker.io/yuanchen12/rcashlar:2026.4.1"

    input:
    tuple val(meta), path(file)

    output:
    tuple val(meta), path("*_markers.csv"), emit: csv
    path "versions.yml"                   , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args      = task.ext.args   ?: ''
    def prefix    = task.ext.prefix ?: "${meta.id}"
    def cycle_arg = (meta.cycle_number != null) ? "--cycle ${meta.cycle_number}" : ""
    """
    cat > _extract_markers.py << 'PYEOF'
    import sys, re, argparse, xml.etree.ElementTree as ET, csv

    def find_channels(root):
        # Get Channel elements from the first Pixels element only.
        # Multi-FOV OME-XML has one Image/Pixels block per tile, each with an
        # identical channel list — collecting from all series gives duplicates.
        pixels = root.find('.//{*}Pixels')
        if pixels is None:
            pixels = root.find('.//Pixels')
        if pixels is not None:
            channels = pixels.findall('{*}Channel')
            if not channels:
                channels = pixels.findall('Channel')
            return channels
        # Fallback for bare XML without a Pixels wrapper
        channels = root.findall('.//{*}Channel')
        if not channels:
            channels = root.findall('.//Channel')
        return channels

    parser = argparse.ArgumentParser()
    parser.add_argument('file')
    parser.add_argument('--cycle', type=int, default=1)
    parser.add_argument('--replace', default=None)
    parser.add_argument('--prefix', required=True)
    pargs = parser.parse_args()

    fname = pargs.file.lower()
    if fname.endswith('.xml'):
        with open(pargs.file) as f:
            xml_str = f.read()
        root = ET.fromstring(xml_str)
        channels = find_channels(root)
        names = [ch.get('Name', f'Channel {i+1}') for i, ch in enumerate(channels)]
        cycle = pargs.cycle
    elif fname.endswith(('.tif', '.tiff')):
        import tifffile
        with tifffile.TiffFile(pargs.file) as tif:
            xml_str = tif.pages[0].tags[270].value
        root = ET.fromstring(xml_str)
        channels = find_channels(root)
        names = [ch.get('Name', f'Channel {i+1}') for i, ch in enumerate(channels)]
        cycle = 1
    else:
        sys.exit(f'Unknown file type: {pargs.file}')

    if pargs.replace:
        pattern = re.compile(pargs.replace)
        names = [pattern.sub('', n) for n in names]

    placeholder = re.compile(r'^Channel\s*\d+$', re.IGNORECASE)
    for name in names:
        if placeholder.match(name):
            print(f'!!! WARNING !!! Channel name looks like an unset OME placeholder: "{name}"', file=sys.stderr)

    with open(f'{pargs.prefix}_markers.csv', 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['channel_number', 'cycle_number', 'marker_name'])
        for i, name in enumerate(names, 1):
            writer.writerow([i, cycle, name])
    PYEOF

    python3 _extract_markers.py "${file}" ${cycle_arg} --prefix "${prefix}" ${args}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo 'channel_number,cycle_number,marker_name' > ${prefix}_markers.csv
    echo '1,1,stub_marker' >> ${prefix}_markers.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: \$(python3 --version | sed 's/Python //')
    END_VERSIONS
    """
}
