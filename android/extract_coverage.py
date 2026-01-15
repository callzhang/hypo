import xml.etree.ElementTree as ET
import sys

def get_coverage(xml_path, classes_arg=None):
    tree = ET.parse(xml_path)
    root = tree.getroot()
    
    # If classes_arg is None or empty, we want ALL classes under com.hypo.clipboard
    # filtering out generated or irrelevant ones.
    filter_all = classes_arg is None or len(classes_arg) == 0

    classes_of_interest = classes_arg if not filter_all else []
    
    results = []

    for package in root.findall('package'):
        for cls in package.findall('class'):
            cls_name = cls.get('name')
            
            # Simple filtering logic
            if filter_all:
                if not cls_name.startswith("com/hypo/clipboard"):
                    continue
                # Skip generated Dagger/Hilt/ViewBinding/Other classes
                if any(x in cls_name for x in ["_Factory", "_MembersInjector", "_HiltBase", "Hilt_", "BuildConfig", "Dagger", "_Impl", "ResultKt", "LiveLiterals"]):
                    continue
                if "$Composable" in cls_name: # Skip Compose generated
                    continue 
            else:
                if cls_name not in classes_of_interest:
                    continue
            
            # Extract metrics
            metrics = {}
            for counter in cls.findall('counter'):
                type = counter.get('type')
                missed = int(counter.get('missed'))
                covered = int(counter.get('covered'))
                total = missed + covered
                metrics[type] = {
                    'covered': covered,
                    'total': total,
                    'pct': (covered / total * 100) if total > 0 else 0
                }
            
            results.append({
                'name': cls_name,
                'metrics': metrics
            })

    # Sort by name
    results.sort(key=lambda x: x['name'])

    for res in results:
        print(f"Class: {res['name']}")
        metrics = res['metrics']
        # Print standard metrics
        for m_type in ['INSTRUCTION', 'BRANCH', 'LINE', 'COMPLEXITY', 'METHOD', 'CLASS']:
            if m_type in metrics:
                data = metrics[m_type]
                print(f"  {m_type}: {data['covered']}/{data['total']} ({data['pct']:.2f}%)")
        print("-" * 20)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 extract_coverage.py <xml_path> [class1 class2 ...]")
        sys.exit(1)
        
    xml_file = sys.argv[1]
    classes = sys.argv[2:] if len(sys.argv) > 2 else None
    get_coverage(xml_file, classes)
