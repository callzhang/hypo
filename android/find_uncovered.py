import xml.etree.ElementTree as ET
import sys

def get_uncovered_lines(xml_path, class_name):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    
    for package in root.findall('package'):
        for cls in package.findall('class'):
            if cls.get('name') == class_name:
                source_file_name = cls.get('sourcefilename')
                # Find the sourcefile element
                source_file = package.find(f"./sourcefile[@name='{source_file_name}']")
                if source_file is not None:
                    print(f"Uncovered lines for {class_name}:")
                    uncovered = []
                    for line in source_file.findall('line'):
                        mi = int(line.get('mi'))
                        if mi > 0:
                            uncovered.append(line.get('nr'))
                    print(", ".join(uncovered))
                return

if __name__ == "__main__":
    get_uncovered_lines(sys.argv[1], sys.argv[2])
